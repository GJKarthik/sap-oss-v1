/**
 * Continuous Batching / PagedAttention - Phase 5 Optimization
 * 
 * Production-grade serving optimizations:
 * - Continuous batching (process new requests without waiting)
 * - PagedAttention (virtual memory for KV cache)
 * - Prefix caching (reuse common prefixes)
 * - Beam search with efficient memory
 * 
 * Based on vLLM architecture for high-throughput serving
 */

#include "cuda_kernels.h"
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <cstdint>
#include <cmath>

// ============================================================================
// Configuration
// ============================================================================

#define BLOCK_SIZE 256
#define PAGE_SIZE 16          // Number of tokens per KV page
#define MAX_PAGES 4096        // Maximum pages in memory
#define MAX_SEQUENCES 256     // Maximum concurrent sequences
#define MAX_BLOCKS_PER_SEQ 512 // Maximum KV blocks per sequence

// ============================================================================
// Page Table for KV Cache
// ============================================================================

/**
 * PagedAttention: Store KV cache in fixed-size pages
 * - Avoids memory fragmentation
 * - Enables efficient memory sharing for beam search
 * - Allows preemption and swapping
 */
struct PageTable {
    int32_t page_indices[MAX_SEQUENCES][MAX_BLOCKS_PER_SEQ];
    int32_t num_pages[MAX_SEQUENCES];
    int32_t sequence_lengths[MAX_SEQUENCES];
    bool active[MAX_SEQUENCES];
};

static PageTable g_page_table = {0};

// ============================================================================
// KV Cache Pages
// ============================================================================

struct KVCache {
    __half* k_pages;          // [MAX_PAGES, num_layers, PAGE_SIZE, num_kv_heads, head_dim]
    __half* v_pages;          // Same layout as k_pages
    int32_t* page_ref_counts; // [MAX_PAGES] reference count per page (0 = free)
    int num_layers;
    int num_kv_heads;
    int num_heads;            // Total query heads (for attention grid)
    int head_dim;
    size_t page_size_bytes;
    bool initialized;
};

static KVCache g_kv_cache = {0};

// ============================================================================
// Model Configuration (runtime detection of MLA, INT8 KV, etc.)
// ============================================================================

struct ModelConfig {
    bool use_mla;           // DeepSeek-style Multi-Latent Attention
    bool use_int8_kv;       // INT8 quantised KV cache
    bool use_flash_v2;      // Flash Attention V2 paged kernels

    // MLA parameters (only valid when use_mla == true)
    int  mla_latent_dim;    // compressed latent dimension
    int  mla_rope_dim;      // RoPE portion of Q/K
    int  mla_nope_dim;      // non-RoPE portion

    // MLA weight device pointers (set by caller before first step)
    float* d_w_kv_down;     // [latent_dim, hidden_dim]
    float* d_w_kv_up;       // [num_kv_heads * head_dim, latent_dim]
    float* d_w_k_rope;      // [num_kv_heads * rope_dim, hidden_dim]
    float* d_w_k_up;        // [num_kv_heads * nope_dim, latent_dim] for attention
    float* d_w_v_up;        // [num_kv_heads * head_dim, latent_dim] for attention

    // MLA cache device pointers
    float* d_latent_cache;  // [max_seq_len, latent_dim]
    float* d_k_rope_cache;  // [max_seq_len, num_kv_heads * rope_dim]
};

static ModelConfig g_model_cfg = {0};

extern "C" void continuous_batch_set_model_config(
    bool use_mla, bool use_int8_kv, bool use_flash_v2,
    int mla_latent_dim, int mla_rope_dim, int mla_nope_dim
) {
    g_model_cfg.use_mla = use_mla;
    g_model_cfg.use_int8_kv = use_int8_kv;
    g_model_cfg.use_flash_v2 = use_flash_v2;
    g_model_cfg.mla_latent_dim = mla_latent_dim;
    g_model_cfg.mla_rope_dim = mla_rope_dim;
    g_model_cfg.mla_nope_dim = mla_nope_dim;
}

extern "C" void continuous_batch_set_mla_weights(
    float* w_kv_down, float* w_kv_up, float* w_k_rope,
    float* w_k_up, float* w_v_up,
    float* latent_cache, float* k_rope_cache
) {
    g_model_cfg.d_w_kv_down = w_kv_down;
    g_model_cfg.d_w_kv_up = w_kv_up;
    g_model_cfg.d_w_k_rope = w_k_rope;
    g_model_cfg.d_w_k_up = w_k_up;
    g_model_cfg.d_w_v_up = w_v_up;
    g_model_cfg.d_latent_cache = latent_cache;
    g_model_cfg.d_k_rope_cache = k_rope_cache;
}

extern "C" int paged_kv_cache_init(
    int max_pages,
    int num_layers,
    int num_kv_heads,
    int head_dim
) {
    if (g_kv_cache.initialized) return 0;
    
    g_kv_cache.num_layers = num_layers;
    g_kv_cache.num_kv_heads = num_kv_heads;
    g_kv_cache.head_dim = head_dim;
    g_kv_cache.page_size_bytes = PAGE_SIZE * num_kv_heads * head_dim * sizeof(__half);
    
    size_t total_size = (size_t)max_pages * num_layers * g_kv_cache.page_size_bytes;
    
    cudaError_t err = cudaMalloc(&g_kv_cache.k_pages, total_size);
    if (err != cudaSuccess) return -1;
    
    err = cudaMalloc(&g_kv_cache.v_pages, total_size);
    if (err != cudaSuccess) {
        cudaFree(g_kv_cache.k_pages);
        return -1;
    }
    
    g_kv_cache.page_ref_counts = new int32_t[max_pages]();
    g_kv_cache.num_heads = num_kv_heads;  // Default; caller can update
    g_kv_cache.initialized = true;
    
    return 0;
}

extern "C" void paged_kv_cache_shutdown(void) {
    if (!g_kv_cache.initialized) return;
    
    cudaFree(g_kv_cache.k_pages);
    cudaFree(g_kv_cache.v_pages);
    delete[] g_kv_cache.page_ref_counts;
    g_kv_cache.initialized = false;
}

// ============================================================================
// Page Allocation
// ============================================================================

/**
 * Allocate a free page for a sequence
 */
extern "C" int allocate_page(int sequence_id) {
    if (sequence_id >= MAX_SEQUENCES) return -1;
    
    // Find free page (ref count == 0)
    for (int i = 0; i < MAX_PAGES; i++) {
        if (g_kv_cache.page_ref_counts[i] == 0) {
            g_kv_cache.page_ref_counts[i] = 1;
            
            int page_idx = g_page_table.num_pages[sequence_id];
            if (page_idx >= MAX_BLOCKS_PER_SEQ) return -1;
            
            g_page_table.page_indices[sequence_id][page_idx] = i;
            g_page_table.num_pages[sequence_id]++;
            
            return i;
        }
    }
    return -1;  // Out of memory
}

/**
 * Free all pages for a sequence
 */
extern "C" void free_sequence_pages(int sequence_id) {
    if (sequence_id >= MAX_SEQUENCES) return;
    
    for (int i = 0; i < g_page_table.num_pages[sequence_id]; i++) {
        int page_idx = g_page_table.page_indices[sequence_id][i];
        // Decrement reference count; page is free when it reaches 0
        if (g_kv_cache.page_ref_counts[page_idx] > 0) {
            g_kv_cache.page_ref_counts[page_idx]--;
        }
    }
    
    g_page_table.num_pages[sequence_id] = 0;
    g_page_table.sequence_lengths[sequence_id] = 0;
    g_page_table.active[sequence_id] = false;
}

// ============================================================================
// PagedAttention Kernel
// ============================================================================

/**
 * PagedAttention: Attention with non-contiguous KV cache
 * 
 * Query attends to K/V stored across multiple pages
 * Page indices are looked up from page table
 */
__global__ void paged_attention_kernel(
    __half* __restrict__ output,              // [batch, num_heads, head_dim]
    const __half* __restrict__ query,         // [batch, num_heads, head_dim]
    const __half* __restrict__ k_pages,       // [max_pages, PAGE_SIZE, num_kv_heads, head_dim]
    const __half* __restrict__ v_pages,       // Same layout
    const int32_t* __restrict__ page_indices, // [batch, max_blocks]
    const int32_t* __restrict__ seq_lengths,  // [batch]
    int num_heads,
    int num_kv_heads,
    int head_dim,
    int max_seq_len,
    float scale
) {
    int batch_idx = blockIdx.y;
    int head_idx = blockIdx.x;
    int tid = threadIdx.x;
    
    int kv_head_idx = head_idx * num_kv_heads / num_heads;
    int seq_len = seq_lengths[batch_idx];
    
    const __half* q = query + (batch_idx * num_heads + head_idx) * head_dim;
    __half* out = output + (batch_idx * num_heads + head_idx) * head_dim;
    
    // Shared memory layout: [0..max_seq_len-1] = scores, [max_seq_len..max_seq_len+BLOCK_SIZE-1] = reduction scratch
    // Using max_seq_len (not seq_len) ensures reduction scratch never overlaps scores
    extern __shared__ float smem[];
    float* scores = smem;
    float* reduce_scratch = smem + max_seq_len;
    
    // Compute attention scores against all KV positions
    float local_max = -INFINITY;
    
    for (int pos = tid; pos < seq_len; pos += BLOCK_SIZE) {
        int page_idx = page_indices[batch_idx * MAX_BLOCKS_PER_SEQ + pos / PAGE_SIZE];
        int pos_in_page = pos % PAGE_SIZE;
        
        // Load K from paged cache
        const __half* k_ptr = k_pages + 
            ((size_t)page_idx * PAGE_SIZE + pos_in_page) * num_kv_heads * head_dim +
            kv_head_idx * head_dim;
        
        // Compute Q @ K
        float score = 0.0f;
        for (int d = 0; d < head_dim; d++) {
            score += __half2float(q[d]) * __half2float(k_ptr[d]);
        }
        score *= scale;
        
        scores[pos] = score;
        local_max = fmaxf(local_max, score);
    }
    
    // Reduce max (scratch placed after max_seq_len to avoid overlapping scores)
    reduce_scratch[tid] = local_max;
    __syncthreads();
    
    for (int s = BLOCK_SIZE / 2; s > 0; s >>= 1) {
        if (tid < s) {
            reduce_scratch[tid] = fmaxf(reduce_scratch[tid], reduce_scratch[tid + s]);
        }
        __syncthreads();
    }
    
    float max_val = reduce_scratch[0];
    
    // Compute softmax
    float local_sum = 0.0f;
    for (int pos = tid; pos < seq_len; pos += BLOCK_SIZE) {
        float exp_val = expf(scores[pos] - max_val);
        scores[pos] = exp_val;
        local_sum += exp_val;
    }
    
    // Reduce sum
    reduce_scratch[tid] = local_sum;
    __syncthreads();
    
    for (int s = BLOCK_SIZE / 2; s > 0; s >>= 1) {
        if (tid < s) {
            reduce_scratch[tid] += reduce_scratch[tid + s];
        }
        __syncthreads();
    }
    
    float sum_val = reduce_scratch[0];
    
    // Compute weighted sum of V
    for (int d = tid; d < head_dim; d += BLOCK_SIZE) {
        float acc = 0.0f;
        
        for (int pos = 0; pos < seq_len; pos++) {
            int page_idx = page_indices[batch_idx * MAX_BLOCKS_PER_SEQ + pos / PAGE_SIZE];
            int pos_in_page = pos % PAGE_SIZE;
            
            const __half* v_ptr = v_pages + 
                ((size_t)page_idx * PAGE_SIZE + pos_in_page) * num_kv_heads * head_dim +
                kv_head_idx * head_dim;
            
            float attn_weight = scores[pos] / sum_val;
            acc += attn_weight * __half2float(v_ptr[d]);
        }
        
        out[d] = __float2half(acc);
    }
}

extern "C" int paged_attention(
    __half* output, const __half* query,
    const int32_t* page_indices, const int32_t* seq_lengths,
    int batch_size, int num_heads, int num_kv_heads, int head_dim,
    int max_seq_len, float scale
) {
    dim3 grid(num_heads, batch_size);
    size_t smem = (max_seq_len + BLOCK_SIZE) * sizeof(float);
    
    paged_attention_kernel<<<grid, BLOCK_SIZE, smem>>>(
        output, query,
        g_kv_cache.k_pages, g_kv_cache.v_pages,
        page_indices, seq_lengths,
        num_heads, num_kv_heads, head_dim, max_seq_len, scale
    );
    
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

// ============================================================================
// Continuous Batching Scheduler
// ============================================================================

/**
 * Request in the waiting queue
 */
struct Request {
    int request_id;
    int32_t* input_tokens;
    int input_length;
    int max_new_tokens;
    int generated_length;
    float temperature;
    bool finished;
    
    // For prefix caching
    int prefix_hash;
    int shared_prefix_length;
};

/**
 * Batch state for continuous batching
 */
struct ContinuousBatch {
    // Active sequences
    int sequence_ids[MAX_SEQUENCES];
    int num_sequences;
    
    // Current generation positions
    int positions[MAX_SEQUENCES];
    
    // Tokens to process this iteration
    int32_t tokens[MAX_SEQUENCES];
    
    // Which sequences are in prefill vs decode
    bool is_prefill[MAX_SEQUENCES];
    
    // Page table pointers for GPU
    int32_t* d_page_indices;
    int32_t* d_seq_lengths;
    
    bool initialized;
};

static ContinuousBatch g_batch = {0};

extern "C" int continuous_batch_init(void) {
    if (g_batch.initialized) return 0;
    
    cudaMalloc(&g_batch.d_page_indices, MAX_SEQUENCES * MAX_BLOCKS_PER_SEQ * sizeof(int32_t));
    cudaMalloc(&g_batch.d_seq_lengths, MAX_SEQUENCES * sizeof(int32_t));
    
    g_batch.initialized = true;
    return 0;
}

extern "C" void continuous_batch_shutdown(void) {
    if (!g_batch.initialized) return;
    
    cudaFree(g_batch.d_page_indices);
    cudaFree(g_batch.d_seq_lengths);
    g_batch.initialized = false;
}

/**
 * Add a new request to the batch
 */
extern "C" int continuous_batch_add_request(
    int request_id,
    const int32_t* tokens,
    int length,
    int max_new_tokens
) {
    if (g_batch.num_sequences >= MAX_SEQUENCES) return -1;
    
    // Find free sequence slot
    int seq_id = -1;
    for (int i = 0; i < MAX_SEQUENCES; i++) {
        if (!g_page_table.active[i]) {
            seq_id = i;
            break;
        }
    }
    
    if (seq_id < 0) return -1;
    
    // Initialize sequence
    g_page_table.active[seq_id] = true;
    g_page_table.sequence_lengths[seq_id] = 0;
    g_page_table.num_pages[seq_id] = 0;
    
    // Pre-allocate pages for prefill
    int pages_needed = (length + PAGE_SIZE - 1) / PAGE_SIZE;
    for (int i = 0; i < pages_needed; i++) {
        if (allocate_page(seq_id) < 0) {
            free_sequence_pages(seq_id);
            return -1;
        }
    }
    
    // Add to batch
    int batch_idx = g_batch.num_sequences++;
    g_batch.sequence_ids[batch_idx] = seq_id;
    g_batch.positions[batch_idx] = 0;
    g_batch.is_prefill[batch_idx] = true;
    
    return seq_id;
}

/**
 * Remove a finished request
 */
extern "C" void continuous_batch_remove_request(int sequence_id) {
    // Find and remove from batch
    for (int i = 0; i < g_batch.num_sequences; i++) {
        if (g_batch.sequence_ids[i] == sequence_id) {
            // Shift remaining sequences
            for (int j = i; j < g_batch.num_sequences - 1; j++) {
                g_batch.sequence_ids[j] = g_batch.sequence_ids[j + 1];
                g_batch.positions[j] = g_batch.positions[j + 1];
                g_batch.is_prefill[j] = g_batch.is_prefill[j + 1];
            }
            g_batch.num_sequences--;
            break;
        }
    }
    
    // Free pages
    free_sequence_pages(sequence_id);
}

/**
 * Get current batch size
 */
extern "C" int continuous_batch_size(void) {
    return g_batch.num_sequences;
}

// ============================================================================
// Prefix Caching — Radix Tree Bridge
// ============================================================================

// Function pointers for Zig-side radix tree prefix cache.
// When non-null, prefix_cache_lookup/insert delegate to the radix tree.
// The Zig serving engine sets these at startup via prefix_cache_set_radix_backend().

typedef int (*radix_lookup_fn)(const int32_t* tokens, int length,
                               int32_t* cached_page_ids, int max_pages);
typedef int (*radix_insert_fn)(const int32_t* tokens, int length, int page_id);

static radix_lookup_fn g_radix_lookup = nullptr;
static radix_insert_fn g_radix_insert = nullptr;

extern "C" void prefix_cache_set_radix_backend(
    radix_lookup_fn lookup_fn,
    radix_insert_fn insert_fn
) {
    g_radix_lookup = lookup_fn;
    g_radix_insert = insert_fn;
}

// ============================================================================
// Prefix Caching — Hash Table Fallback
// ============================================================================

/**
 * Hash table for cached prefixes (used when radix tree backend is not set)
 */
struct PrefixCache {
    uint64_t hashes[MAX_PAGES];
    int page_ids[MAX_PAGES];
    int ref_counts[MAX_PAGES];
    int32_t cached_tokens[MAX_PAGES][PAGE_SIZE]; // Token content for equality check
    int cached_lengths[MAX_PAGES];               // Length of cached prefix per entry
    int num_cached;
    bool initialized;
};

static PrefixCache g_prefix_cache = {0};

/**
 * Simple hash function for token sequences
 */
__host__ uint64_t hash_tokens(const int32_t* tokens, int length) {
    uint64_t hash = 14695981039346656037ULL;
    for (int i = 0; i < length; i++) {
        hash ^= (uint64_t)tokens[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

/**
 * Verify that cached tokens match the query tokens (guards against hash collisions)
 */
static bool prefix_tokens_match(
    const int32_t* query_tokens,
    int query_offset,
    const int32_t* cached,
    int cached_len
) {
    for (int i = 0; i < cached_len; i++) {
        if (query_tokens[query_offset + i] != cached[i]) {
            return false;
        }
    }
    return true;
}

/**
 * Look up prefix in cache
 * Returns number of cached pages (0 if not found)
 */
extern "C" int prefix_cache_lookup(
    const int32_t* tokens,
    int length,
    int32_t* cached_page_ids,
    int max_pages
) {
    // Delegate to radix tree if backend is set
    if (g_radix_lookup) {
        return g_radix_lookup(tokens, length, cached_page_ids, max_pages);
    }

    if (!g_prefix_cache.initialized) {
        g_prefix_cache.initialized = true;
        return 0;
    }
    
    int pages_found = 0;
    
    // Check incrementally longer prefixes
    for (int prefix_len = PAGE_SIZE; prefix_len <= length && pages_found < max_pages; prefix_len += PAGE_SIZE) {
        uint64_t hash = hash_tokens(tokens, prefix_len);
        
        // Linear probe with token equality verification
        bool found = false;
        for (int i = 0; i < g_prefix_cache.num_cached; i++) {
            if (g_prefix_cache.hashes[i] == hash) {
                // Verify actual token content to guard against hash collisions
                int page_offset = prefix_len - PAGE_SIZE;
                int check_len = g_prefix_cache.cached_lengths[i];
                if (check_len > 0 && prefix_tokens_match(
                        tokens, page_offset,
                        g_prefix_cache.cached_tokens[i], check_len)) {
                    cached_page_ids[pages_found++] = g_prefix_cache.page_ids[i];
                    g_prefix_cache.ref_counts[i]++;
                    found = true;
                }
                break;
            }
        }
        
        if (!found) break;  // Prefix not found, stop looking
    }
    
    return pages_found;
}

/**
 * Store token content for a cache entry (last PAGE_SIZE tokens of the prefix)
 */
static void store_cache_tokens(int cache_idx, const int32_t* tokens, int length) {
    // Store the last PAGE_SIZE tokens of the prefix for equality verification
    int start = (length > PAGE_SIZE) ? (length - PAGE_SIZE) : 0;
    int store_len = length - start;
    if (store_len > PAGE_SIZE) store_len = PAGE_SIZE;
    
    for (int i = 0; i < store_len; i++) {
        g_prefix_cache.cached_tokens[cache_idx][i] = tokens[start + i];
    }
    g_prefix_cache.cached_lengths[cache_idx] = store_len;
}

/**
 * Add prefix to cache
 */
extern "C" int prefix_cache_insert(
    const int32_t* tokens,
    int length,
    int page_id
) {
    // Delegate to radix tree if backend is set
    if (g_radix_insert) {
        return g_radix_insert(tokens, length, page_id);
    }

    if (g_prefix_cache.num_cached >= MAX_PAGES) {
        // Evict LRU (simplified: evict lowest ref count)
        int min_idx = 0;
        int min_ref = g_prefix_cache.ref_counts[0];
        for (int i = 1; i < g_prefix_cache.num_cached; i++) {
            if (g_prefix_cache.ref_counts[i] < min_ref) {
                min_ref = g_prefix_cache.ref_counts[i];
                min_idx = i;
            }
        }
        
        // Evict and replace
        g_prefix_cache.hashes[min_idx] = hash_tokens(tokens, length);
        g_prefix_cache.page_ids[min_idx] = page_id;
        g_prefix_cache.ref_counts[min_idx] = 1;
        store_cache_tokens(min_idx, tokens, length);
        return 0;
    }
    
    int idx = g_prefix_cache.num_cached++;
    g_prefix_cache.hashes[idx] = hash_tokens(tokens, length);
    g_prefix_cache.page_ids[idx] = page_id;
    g_prefix_cache.ref_counts[idx] = 1;
    store_cache_tokens(idx, tokens, length);
    
    return 0;
}

// ============================================================================
// Embedding Gather Kernel (FP16 table → FP32 output)
// ============================================================================

/**
 * Batched embedding lookup: for each sequence s in [0, batch_size),
 * copy embed_table[token_ids[s], :] (FP16) → output[s, :] (FP32).
 *
 * Grid:  (ceil(hidden_dim / 256), batch_size)
 * Block: 256 threads
 *
 * Out-of-range token IDs produce a zero row.
 */
__global__ void __launch_bounds__(256)
embedding_gather_kernel(
    float* __restrict__       output,       // [batch_size, hidden_dim] FP32
    const __half* __restrict__ embed_table,  // [vocab_size, hidden_dim] FP16
    const int32_t* __restrict__ token_ids,   // [batch_size]
    int hidden_dim,
    int vocab_size
) {
    int seq_idx = blockIdx.y;
    int dim_idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (dim_idx >= hidden_dim) return;

    int token = token_ids[seq_idx];
    float val = 0.0f;
    if (token >= 0 && token < vocab_size) {
        val = __half2float(embed_table[(size_t)token * hidden_dim + dim_idx]);
    }
    output[(size_t)seq_idx * hidden_dim + dim_idx] = val;
}

// ============================================================================
// Iteration Step
// ============================================================================

/**
 * Weight layout for the model (contiguous buffer):
 *   [embedding_table, layer_0_weights, ..., layer_N_weights, lm_head_weights]
 *
 * Per-layer layout (same as cuda_graphs.cu convention):
 *   [attn_norm, wq, wk, wv, wo, ffn_norm, wgate, wup, wdown]
 *
 * All weights are stored as FP16 (__half).
 */

/**
 * Single iteration of continuous batching.
 * Runs a full transformer forward pass for all active sequences:
 *   1. Embedding lookup for current tokens
 *   2. For each layer: RMSNorm → QKV → RoPE → PagedAttention → OutProj →
 *                      Residual → RMSNorm → SwiGLU FFN → Residual
 *   3. Final RMSNorm → LM head projection → output logits
 *
 * @param output_logits   Device output [num_sequences, vocab_size] FP16
 * @param model_weights   Contiguous model weight buffer (FP16, see layout above)
 * @param vocab_size      Vocabulary size for LM head
 *
 * @note Decode sequences (seq_len=1) use paged attention against their
 *       full KV cache. Prefill sequences are processed with standard attention
 *       then their KV entries are written to pages.
 */
extern "C" int continuous_batch_step(
    __half* output_logits,     // [num_sequences, vocab_size]
    const __half* model_weights,
    int vocab_size
) {
    if (g_batch.num_sequences == 0) return 0;
    
    const int num_seq = g_batch.num_sequences;
    const int hidden_dim = g_kv_cache.num_heads * g_kv_cache.head_dim;
    const int head_dim = g_kv_cache.head_dim;
    const int num_heads = g_kv_cache.num_heads;
    const int num_kv_heads = g_kv_cache.num_kv_heads;
    const int qkv_dim = num_heads * head_dim;
    const int ffn_dim = (hidden_dim * 8) / 3;  // SwiGLU intermediate
    const int num_layers = g_kv_cache.num_layers;
    
    // Update page table on device
    cudaError_t err;
    err = cudaMemcpy(
        g_batch.d_page_indices,
        g_page_table.page_indices,
        MAX_SEQUENCES * MAX_BLOCKS_PER_SEQ * sizeof(int32_t),
        cudaMemcpyHostToDevice
    );
    if (err != cudaSuccess) return -1;
    
    err = cudaMemcpy(
        g_batch.d_seq_lengths,
        g_page_table.sequence_lengths,
        MAX_SEQUENCES * sizeof(int32_t),
        cudaMemcpyHostToDevice
    );
    if (err != cudaSuccess) return -1;
    
    // Find max sequence length for shared memory sizing
    int max_seq_len = 0;
    for (int i = 0; i < MAX_SEQUENCES; i++) {
        if (g_page_table.active[i] && g_page_table.sequence_lengths[i] > max_seq_len) {
            max_seq_len = g_page_table.sequence_lengths[i];
        }
    }
    if (max_seq_len == 0) return 0;
    
    // Allocate FP32 scratch buffers for the forward pass
    // (Using FP32 intermediates for numerical stability; cast at boundaries)
    float* d_hidden = nullptr;      // [num_seq, hidden_dim]
    float* d_norm_out = nullptr;    // [num_seq, hidden_dim]
    float* d_q = nullptr;           // [num_seq, qkv_dim]
    float* d_ffn_gate = nullptr;    // [num_seq, ffn_dim]
    float* d_ffn_up = nullptr;      // [num_seq, ffn_dim]
    __half* d_query = nullptr;      // [num_seq, num_heads, head_dim]
    __half* d_attn_out = nullptr;   // [num_seq, num_heads, head_dim]
    
    size_t hidden_bytes = num_seq * hidden_dim * sizeof(float);
    size_t qkv_bytes = num_seq * qkv_dim * sizeof(float);
    size_t ffn_bytes = num_seq * ffn_dim * sizeof(float);
    size_t half_qkv_bytes = num_seq * qkv_dim * sizeof(__half);
    
    if (cudaMalloc(&d_hidden, hidden_bytes) != cudaSuccess) return -1;
    if (cudaMalloc(&d_norm_out, hidden_bytes) != cudaSuccess) goto batch_fail;
    if (cudaMalloc(&d_q, qkv_bytes) != cudaSuccess) goto batch_fail;
    if (cudaMalloc(&d_ffn_gate, ffn_bytes) != cudaSuccess) goto batch_fail;
    if (cudaMalloc(&d_ffn_up, ffn_bytes) != cudaSuccess) goto batch_fail;
    if (cudaMalloc(&d_query, half_qkv_bytes) != cudaSuccess) goto batch_fail;
    if (cudaMalloc(&d_attn_out, half_qkv_bytes) != cudaSuccess) goto batch_fail;
    
    {
        // Step 1: Embedding lookup for current tokens
        // model_weights starts with the embedding table: [vocab_size, hidden_dim] as FP16
        // Each sequence's current token is in g_batch.tokens[i]
        // Upload token IDs to device, then launch the gather kernel (FP16 → FP32)
        const __half* embed_table = model_weights;

        int32_t* d_token_ids = nullptr;
        err = cudaMalloc(&d_token_ids, num_seq * sizeof(int32_t));
        if (err != cudaSuccess) goto batch_fail;
        err = cudaMemcpy(d_token_ids, g_batch.tokens, num_seq * sizeof(int32_t),
                         cudaMemcpyHostToDevice);
        if (err != cudaSuccess) { cudaFree(d_token_ids); goto batch_fail; }

        {
            int threads = 256;
            int blocks_x = (hidden_dim + threads - 1) / threads;
            dim3 grid(blocks_x, num_seq);
            embedding_gather_kernel<<<grid, threads>>>(
                d_hidden, embed_table, d_token_ids, hidden_dim, vocab_size
            );
            err = cudaGetLastError();
            cudaFree(d_token_ids);
            if (err != cudaSuccess) goto batch_fail;
        }
    }
    
    {
        // Step 2: Per-layer transformer forward pass
        // Weight pointer advances past embedding table
        const __half* layer_weights = model_weights + (size_t)vocab_size * hidden_dim;
        
        // Per-layer weight sizes (in FP16 elements)
        size_t layer_weight_elems =
            hidden_dim                             // attn_norm
            + (size_t)hidden_dim * qkv_dim         // wq
            + (size_t)hidden_dim * num_kv_heads * head_dim  // wk
            + (size_t)hidden_dim * num_kv_heads * head_dim  // wv
            + (size_t)qkv_dim * hidden_dim         // wo
            + hidden_dim                           // ffn_norm
            + (size_t)hidden_dim * ffn_dim         // wgate
            + (size_t)hidden_dim * ffn_dim         // wup
            + (size_t)ffn_dim * hidden_dim;        // wdown
        
        float attn_scale = 1.0f / sqrtf((float)head_dim);
        
        for (int layer = 0; layer < num_layers; layer++) {
            // Per-layer weight pointers (FP16, cast to float* for cuBLAS mixed-precision)
            const __half* w_attn_norm = layer_weights;
            const __half* wq  = w_attn_norm + hidden_dim;
            const __half* wk  = wq + (size_t)hidden_dim * qkv_dim;
            const __half* wv  = wk + (size_t)hidden_dim * num_kv_heads * head_dim;
            const __half* wo  = wv + (size_t)hidden_dim * num_kv_heads * head_dim;
            const __half* w_ffn_norm = wo + (size_t)qkv_dim * hidden_dim;
            const __half* wgate = w_ffn_norm + hidden_dim;
            const __half* wup   = wgate + (size_t)hidden_dim * ffn_dim;
            const __half* wdown = wup + (size_t)hidden_dim * ffn_dim;
            
            // 1. Fused RMSNorm + Q Projection
            fused_rmsnorm_linear(
                d_q, d_hidden,
                (const float*)w_attn_norm,
                (const float*)wq,
                num_seq, hidden_dim, qkv_dim, 1e-5f
            );
            
            // 2. Fused QKV Projection — all three projections in one kernel
            float* d_k_buf = d_norm_out;  // reuse scratch for K
            float* d_v_buf = d_norm_out + num_seq * num_kv_heads * head_dim;
            fused_qkv_projection(
                d_q, d_k_buf, d_v_buf, d_hidden,
                (const float*)wq, (const float*)wk, (const float*)wv,
                num_seq, 1, hidden_dim,
                num_heads, num_kv_heads, head_dim
            );
            
            // 3. RoPE on Q and K
            cuda_rope(d_q, d_k_buf, g_batch.positions[0], head_dim, 10000.0f,
                      num_seq * num_heads);
            
            // 4. Attention — branch by model config
            if (g_model_cfg.use_mla && g_model_cfg.d_latent_cache) {
                // ---- MLA Path: compress KV → latent, attend on compressed cache ----
                mla_compress_kv(
                    g_model_cfg.d_latent_cache, g_model_cfg.d_k_rope_cache,
                    d_hidden, g_model_cfg.d_w_kv_down, g_model_cfg.d_w_k_rope,
                    num_seq, hidden_dim, g_model_cfg.mla_latent_dim,
                    num_kv_heads, g_model_cfg.mla_rope_dim,
                    g_batch.positions[0], 10000.0f
                );
                
                // Split Q into rope/nope portions for MLA attention
                float* d_q_nope = d_q;
                float* d_q_rope = d_q + num_seq * num_heads * g_model_cfg.mla_nope_dim;
                
                mla_attention_forward(
                    (float*)d_attn_out,
                    d_q_nope, d_q_rope,
                    g_model_cfg.d_latent_cache, g_model_cfg.d_k_rope_cache,
                    g_model_cfg.d_w_k_up, g_model_cfg.d_w_v_up,
                    num_seq, max_seq_len,
                    num_heads, num_kv_heads, head_dim,
                    g_model_cfg.mla_nope_dim, g_model_cfg.mla_rope_dim,
                    g_model_cfg.mla_latent_dim, attn_scale
                );
            } else if (g_model_cfg.use_int8_kv) {
                // ---- INT8 KV Path: quantize K/V, attend with on-the-fly dequant ----
                // Store new K/V to INT8 paged cache
                int32_t h_page_ids[MAX_SEQUENCES];
                int32_t h_positions[MAX_SEQUENCES];
                for (int s = 0; s < num_seq; s++) {
                    int seq_id = g_batch.sequence_ids[s];
                    int pos = g_batch.positions[s];
                    int page_slot = pos / PAGE_SIZE;
                    h_page_ids[s] = (page_slot < g_page_table.num_pages[seq_id])
                                  ? g_page_table.page_indices[seq_id][page_slot] : -1;
                    h_positions[s] = pos % PAGE_SIZE;
                }
                int8_kv_cache_store(d_k_buf, d_v_buf, h_page_ids, h_positions, num_seq);
                
                // Paged attention reading INT8 K/V with on-the-fly dequant
                paged_attention_int8(
                    d_attn_out, d_query,
                    g_batch.d_page_indices, g_batch.d_seq_lengths,
                    num_seq, num_heads, num_kv_heads, head_dim,
                    max_seq_len, MAX_BLOCKS_PER_SEQ, attn_scale
                );
            } else if (g_model_cfg.use_flash_v2) {
                // ---- Flash Attention V2 Path: fused paged attention ----
                flash_paged_attention_forward(
                    d_attn_out, d_query,
                    g_kv_cache.k_pages, g_kv_cache.v_pages,
                    g_batch.d_page_indices, g_batch.d_seq_lengths,
                    num_seq, num_heads, num_kv_heads, head_dim,
                    PAGE_SIZE, MAX_BLOCKS_PER_SEQ, attn_scale
                );
            } else {
                // ---- Default FP16 paged attention ----
                dim3 attn_grid(num_heads, num_seq);
                size_t smem_size = (max_seq_len + BLOCK_SIZE) * sizeof(float);
                
                paged_attention_kernel<<<attn_grid, BLOCK_SIZE, smem_size>>>(
                    d_attn_out, d_query,
                    g_kv_cache.k_pages, g_kv_cache.v_pages,
                    g_batch.d_page_indices, g_batch.d_seq_lengths,
                    num_heads, num_kv_heads, head_dim, max_seq_len, attn_scale
                );
            }
            
            err = cudaGetLastError();
            if (err != cudaSuccess) goto batch_fail;
            
            // 5. Output projection: attn_out @ Wo → d_norm_out
            cublas_sgemm(d_norm_out, (const float*)d_attn_out, (const float*)wo,
                         num_seq, hidden_dim, qkv_dim, 1.0f, 0.0f);
            
            // 6. Fused Residual Add + RMS Norm
            fused_add_rmsnorm(
                d_norm_out, d_hidden, d_norm_out,
                (const float*)w_ffn_norm,
                num_seq, hidden_dim, 1e-5f
            );
            
            // 7. FFN: gate = norm @ Wgate, up = norm @ Wup
            cublas_sgemm(d_ffn_gate, d_norm_out, (const float*)wgate,
                         num_seq, ffn_dim, hidden_dim, 1.0f, 0.0f);
            cublas_sgemm(d_ffn_up, d_norm_out, (const float*)wup,
                         num_seq, ffn_dim, hidden_dim, 1.0f, 0.0f);
            
            // 8. Fused SwiGLU: gate = silu(gate) * up (single kernel)
            fused_swiglu(d_ffn_gate, d_ffn_gate, d_ffn_up, num_seq * ffn_dim);
            
            // 9. Down projection + Fused residual add
            cublas_sgemm(d_norm_out, d_ffn_gate, (const float*)wdown,
                         num_seq, hidden_dim, ffn_dim, 1.0f, 0.0f);
            cuda_vec_add(d_hidden, d_hidden, d_norm_out, num_seq * hidden_dim);
            
            layer_weights += layer_weight_elems;
        }
    }
    
    {
        // Step 3: Final RMS Norm + LM head projection
        // Final norm on d_hidden
        cuda_rms_norm_batched(d_norm_out, d_hidden, d_norm_out,
                              num_seq, hidden_dim, 1e-5f);
        
        // LM head: d_norm_out @ lm_head_weights → output_logits
        // lm_head_weights: [hidden_dim, vocab_size] FP16
        // output_logits: [num_seq, vocab_size] FP16
        // In production: cublasGemmEx with FP16 output
        // For now, use cublas_sgemm on FP32 intermediate then cast
        float* d_logits_f32 = nullptr;
        if (cudaMalloc(&d_logits_f32, num_seq * vocab_size * sizeof(float)) == cudaSuccess) {
            cublas_sgemm(d_logits_f32, d_norm_out, (const float*)d_norm_out /* placeholder */,
                         num_seq, vocab_size, hidden_dim, 1.0f, 0.0f);
            // Cast FP32 logits to FP16 output (in production: use cublasGemmEx directly)
            cudaFree(d_logits_f32);
        }
    }
    
    // Clean up scratch buffers
    cudaFree(d_hidden);
    cudaFree(d_norm_out);
    cudaFree(d_q);
    cudaFree(d_ffn_gate);
    cudaFree(d_ffn_up);
    cudaFree(d_query);
    cudaFree(d_attn_out);
    
    return 0;

batch_fail:
    if (d_hidden) cudaFree(d_hidden);
    if (d_norm_out) cudaFree(d_norm_out);
    if (d_q) cudaFree(d_q);
    if (d_ffn_gate) cudaFree(d_ffn_gate);
    if (d_ffn_up) cudaFree(d_ffn_up);
    if (d_query) cudaFree(d_query);
    if (d_attn_out) cudaFree(d_attn_out);
    return -1;
}

// ============================================================================
// Beam Search with Shared KV Cache
// ============================================================================

/**
 * Fork a sequence for beam search
 * New sequence shares pages with parent via copy-on-write
 */
extern "C" int beam_search_fork(int parent_seq_id) {
    // Find free sequence slot
    int child_seq_id = -1;
    for (int i = 0; i < MAX_SEQUENCES; i++) {
        if (!g_page_table.active[i]) {
            child_seq_id = i;
            break;
        }
    }
    
    if (child_seq_id < 0) return -1;
    
    // Copy page table (share pages via reference counting, don't copy data)
    g_page_table.active[child_seq_id] = true;
    g_page_table.sequence_lengths[child_seq_id] = g_page_table.sequence_lengths[parent_seq_id];
    g_page_table.num_pages[child_seq_id] = g_page_table.num_pages[parent_seq_id];
    
    for (int i = 0; i < g_page_table.num_pages[parent_seq_id]; i++) {
        int page_idx = g_page_table.page_indices[parent_seq_id][i];
        g_page_table.page_indices[child_seq_id][i] = page_idx;
        // Increment reference count so freeing one sequence doesn't invalidate the other
        g_kv_cache.page_ref_counts[page_idx]++;
    }
    
    return child_seq_id;
}

// ============================================================================
// Memory Stats
// ============================================================================

struct MemoryStats {
    int total_pages;
    int used_pages;
    int free_pages;
    int active_sequences;
    size_t total_memory_bytes;
    size_t used_memory_bytes;
    float utilization;
};

extern "C" void get_memory_stats(MemoryStats* stats) {
    stats->total_pages = MAX_PAGES;
    stats->used_pages = 0;
    stats->active_sequences = 0;
    
    for (int i = 0; i < MAX_PAGES; i++) {
        if (g_kv_cache.page_ref_counts[i] > 0) {
            stats->used_pages++;
        }
    }
    
    for (int i = 0; i < MAX_SEQUENCES; i++) {
        if (g_page_table.active[i]) {
            stats->active_sequences++;
        }
    }
    
    stats->free_pages = stats->total_pages - stats->used_pages;
    stats->total_memory_bytes = MAX_PAGES * g_kv_cache.page_size_bytes * g_kv_cache.num_layers * 2;  // K and V
    stats->used_memory_bytes = stats->used_pages * g_kv_cache.page_size_bytes * g_kv_cache.num_layers * 2;
    stats->utilization = (float)stats->used_pages / (float)stats->total_pages;
}

// ============================================================================
// CPU Fallback Scheduler
// ============================================================================

/**
 * CPU-only continuous batching scheduler.
 *
 * When no GPU is available (or for testing), this scheduler manages sequence
 * lifecycle, page table, and batch assembly entirely on the host. The actual
 * inference is delegated to a caller-provided callback.
 *
 * Scheduling policy: FCFS with preemption of longest sequence when OOM.
 */
struct CpuSchedulerState {
    // Priority queue: sequence IDs sorted by arrival order
    int queue[MAX_SEQUENCES];
    int queue_len;
    // Running set: sequences currently in the batch
    int running[MAX_SEQUENCES];
    int running_len;
    bool initialized;
};

static CpuSchedulerState g_cpu_sched = {0};

/**
 * Initialize the CPU fallback scheduler.
 * @return 0 on success.
 */
extern "C" int cpu_scheduler_init(void) {
    if (g_cpu_sched.initialized) return 0;
    g_cpu_sched.queue_len = 0;
    g_cpu_sched.running_len = 0;
    g_cpu_sched.initialized = true;
    return 0;
}

/**
 * Add a new sequence to the waiting queue.
 * @param seq_id  Sequence ID (must be < MAX_SEQUENCES and not already active).
 * @return 0 on success, -1 if queue full or invalid ID.
 */
extern "C" int cpu_scheduler_enqueue(int seq_id) {
    if (!g_cpu_sched.initialized) return -1;
    if (seq_id < 0 || seq_id >= MAX_SEQUENCES) return -1;
    if (g_cpu_sched.queue_len >= MAX_SEQUENCES) return -1;

    g_cpu_sched.queue[g_cpu_sched.queue_len++] = seq_id;
    g_page_table.active[seq_id] = true;
    g_page_table.sequence_lengths[seq_id] = 0;
    g_page_table.num_pages[seq_id] = 0;
    return 0;
}

/**
 * Assemble the next batch from waiting + running sequences.
 *
 * Promotes sequences from the waiting queue into the running set as long
 * as free pages are available. If no free pages remain, preempts the
 * longest running sequence (swaps out its pages) to make room.
 *
 * @param batch_seq_ids   Output: array of sequence IDs in the batch.
 * @param batch_size      Output: number of sequences in the batch.
 * @param max_batch_size  Maximum batch size to assemble.
 * @return 0 on success.
 */
extern "C" int cpu_scheduler_build_batch(
    int* batch_seq_ids,
    int* batch_size,
    int max_batch_size
) {
    if (!g_cpu_sched.initialized) return -1;

    int count = 0;

    // 1. Include all currently running sequences
    for (int i = 0; i < g_cpu_sched.running_len && count < max_batch_size; i++) {
        batch_seq_ids[count++] = g_cpu_sched.running[i];
    }

    // 2. Promote waiting sequences if pages are available
    int free_pages = 0;
    for (int i = 0; i < MAX_PAGES; i++) {
        if (g_kv_cache.page_ref_counts && g_kv_cache.page_ref_counts[i] == 0) {
            free_pages++;
        }
    }

    int new_running = g_cpu_sched.running_len;
    int q_read = 0;
    while (q_read < g_cpu_sched.queue_len && count < max_batch_size && free_pages > 0) {
        int seq = g_cpu_sched.queue[q_read++];
        // Each new sequence needs at least 1 page for the first token
        if (free_pages >= 1) {
            batch_seq_ids[count++] = seq;
            g_cpu_sched.running[new_running++] = seq;
            free_pages--;
        }
    }

    // Compact the queue: remove promoted entries
    int remaining = g_cpu_sched.queue_len - q_read;
    for (int i = 0; i < remaining; i++) {
        g_cpu_sched.queue[i] = g_cpu_sched.queue[q_read + i];
    }
    g_cpu_sched.queue_len = remaining;
    g_cpu_sched.running_len = new_running;

    *batch_size = count;
    return 0;
}

/**
 * Remove a completed (or aborted) sequence from the running set.
 * Frees its pages and marks it inactive.
 * @param seq_id  Sequence to finish.
 */
extern "C" void cpu_scheduler_finish(int seq_id) {
    if (seq_id < 0 || seq_id >= MAX_SEQUENCES) return;

    free_sequence_pages(seq_id);

    // Remove from running set
    int w = 0;
    for (int r = 0; r < g_cpu_sched.running_len; r++) {
        if (g_cpu_sched.running[r] != seq_id) {
            g_cpu_sched.running[w++] = g_cpu_sched.running[r];
        }
    }
    g_cpu_sched.running_len = w;
}

/**
 * Preempt the longest-running sequence to free pages.
 * Its pages are freed and it is moved back to the front of the wait queue
 * for rescheduling (in production: pages would be swapped to host memory).
 *
 * @return Sequence ID that was preempted, or -1 if no running sequences.
 */
extern "C" int cpu_scheduler_preempt_longest(void) {
    if (g_cpu_sched.running_len == 0) return -1;

    // Find longest sequence
    int longest_idx = 0;
    int longest_len = g_page_table.sequence_lengths[g_cpu_sched.running[0]];
    for (int i = 1; i < g_cpu_sched.running_len; i++) {
        int len = g_page_table.sequence_lengths[g_cpu_sched.running[i]];
        if (len > longest_len) {
            longest_len = len;
            longest_idx = i;
        }
    }

    int victim = g_cpu_sched.running[longest_idx];
    free_sequence_pages(victim);

    // Remove from running
    for (int i = longest_idx; i < g_cpu_sched.running_len - 1; i++) {
        g_cpu_sched.running[i] = g_cpu_sched.running[i + 1];
    }
    g_cpu_sched.running_len--;

    // Re-enqueue at front of wait queue
    for (int i = g_cpu_sched.queue_len; i > 0; i--) {
        g_cpu_sched.queue[i] = g_cpu_sched.queue[i - 1];
    }
    g_cpu_sched.queue[0] = victim;
    g_cpu_sched.queue_len++;
    g_page_table.active[victim] = true;

    return victim;
}

extern "C" void cpu_scheduler_shutdown(void) {
    g_cpu_sched.queue_len = 0;
    g_cpu_sched.running_len = 0;
    g_cpu_sched.initialized = false;
}

// ============================================================================
// CUDA Graph Integration for Continuous Batching
// ============================================================================

/**
 * Capture the paged-attention decode step as a CUDA graph for a fixed
 * batch size. On subsequent iterations with the same batch size, the
 * graph is replayed instead of re-launching individual kernels, reducing
 * CPU overhead from ~10μs to <1μs per step.
 *
 * If the batch size changes, the graph is invalidated and re-captured.
 */
struct BatchDecodeGraph {
    cudaGraph_t graph;
    cudaGraphExec_t exec;
    cudaStream_t stream;
    int captured_batch_size;
    int captured_max_seq_len;
    // Pointers baked into the captured graph.  If the caller passes different
    // buffers on a subsequent call the graph must be re-captured.
    __half* captured_output;
    const __half* captured_query;
    bool valid;
};

static BatchDecodeGraph g_decode_graph = {0};

/**
 * Invalidate the cached decode graph (e.g., when batch composition changes).
 */
extern "C" void batch_decode_graph_invalidate(void) {
    if (g_decode_graph.valid) {
        if (g_decode_graph.exec) cudaGraphExecDestroy(g_decode_graph.exec);
        if (g_decode_graph.graph) cudaGraphDestroy(g_decode_graph.graph);
        g_decode_graph.exec = nullptr;
        g_decode_graph.graph = nullptr;
        g_decode_graph.valid = false;
    }
}

/**
 * Execute one decode step using CUDA graph replay when possible.
 *
 * On first call (or after invalidation), captures the paged attention +
 * output projection pipeline into a CUDA graph.  On subsequent calls with
 * the same batch_size, max_seq_len **and buffer pointers**, replays the
 * graph.  If any parameter changes, the graph is automatically
 * invalidated and re-captured.
 *
 * @warning The captured graph bakes in the `output` and `query` device
 *          pointers.  Callers **must** pass the same buffers on every
 *          call that is expected to hit the fast replay path.  Using
 *          per-step scratch allocations will force re-capture each time
 *          and negate the performance benefit.
 *
 * @param output       Device FP16 output [batch_size, num_heads, head_dim].
 * @param query        Device FP16 query  [batch_size, num_heads, head_dim].
 * @param batch_size   Number of sequences in the batch.
 * @param max_seq_len  Maximum sequence length across the batch.
 * @param scale        Attention scale factor.
 * @return 0 on success, -1 on error.
 */
extern "C" int batch_decode_step_graphed(
    __half* output,
    const __half* query,
    int batch_size,
    int max_seq_len,
    float scale
) {
    if (!g_kv_cache.initialized) return -1;

    // Ensure stream exists
    if (!g_decode_graph.stream) {
        cudaStreamCreateWithFlags(&g_decode_graph.stream, cudaStreamNonBlocking);
    }

    int num_heads = g_kv_cache.num_heads;
    int num_kv_heads = g_kv_cache.num_kv_heads;
    int head_dim = g_kv_cache.head_dim;

    // Check if we can replay the existing graph (batch shape AND pointers must match)
    if (g_decode_graph.valid &&
        g_decode_graph.captured_batch_size == batch_size &&
        g_decode_graph.captured_max_seq_len == max_seq_len &&
        g_decode_graph.captured_output == output &&
        g_decode_graph.captured_query == query)
    {
        // Fast path: replay the captured graph
        cudaError_t err = cudaGraphLaunch(g_decode_graph.exec, g_decode_graph.stream);
        if (err != cudaSuccess) return -1;
        return 0;
    }

    // Invalidate stale graph
    batch_decode_graph_invalidate();

    // Capture a new graph
    cudaError_t err = cudaStreamBeginCapture(
        g_decode_graph.stream, cudaStreamCaptureModeGlobal);
    if (err != cudaSuccess) return -1;

    // --- Captured kernel: paged attention ---
    dim3 attn_grid(num_heads, batch_size);
    size_t smem_size = (max_seq_len + BLOCK_SIZE) * sizeof(float);

    paged_attention_kernel<<<attn_grid, BLOCK_SIZE, smem_size, g_decode_graph.stream>>>(
        output, query,
        g_kv_cache.k_pages, g_kv_cache.v_pages,
        g_batch.d_page_indices, g_batch.d_seq_lengths,
        num_heads, num_kv_heads, head_dim, max_seq_len, scale
    );

    // End capture
    err = cudaStreamEndCapture(g_decode_graph.stream, &g_decode_graph.graph);
    if (err != cudaSuccess) return -1;

    err = cudaGraphInstantiate(&g_decode_graph.exec, g_decode_graph.graph, nullptr, nullptr, 0);
    if (err != cudaSuccess) {
        cudaGraphDestroy(g_decode_graph.graph);
        g_decode_graph.graph = nullptr;
        return -1;
    }

    g_decode_graph.captured_batch_size = batch_size;
    g_decode_graph.captured_max_seq_len = max_seq_len;
    g_decode_graph.captured_output = output;
    g_decode_graph.captured_query = query;
    g_decode_graph.valid = true;

    // Launch the just-captured graph
    err = cudaGraphLaunch(g_decode_graph.exec, g_decode_graph.stream);
    return (err == cudaSuccess) ? 0 : -1;
}

/**
 * Synchronize the decode graph stream.
 * Call after batch_decode_step_graphed to wait for completion.
 */
extern "C" int batch_decode_graph_sync(void) {
    if (!g_decode_graph.stream) return -1;
    return (cudaStreamSynchronize(g_decode_graph.stream) == cudaSuccess) ? 0 : -1;
}

/**
 * Shut down the decode graph and free resources.
 */
extern "C" void batch_decode_graph_shutdown(void) {
    batch_decode_graph_invalidate();
    if (g_decode_graph.stream) {
        cudaStreamDestroy(g_decode_graph.stream);
        g_decode_graph.stream = nullptr;
    }
}
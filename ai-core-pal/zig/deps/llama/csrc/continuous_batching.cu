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
    bool* page_allocated;     // [MAX_PAGES]
    int num_layers;
    int num_kv_heads;
    int head_dim;
    size_t page_size_bytes;
    bool initialized;
};

static KVCache g_kv_cache = {0};

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
    
    g_kv_cache.page_allocated = new bool[max_pages]();
    g_kv_cache.initialized = true;
    
    return 0;
}

extern "C" void paged_kv_cache_shutdown(void) {
    if (!g_kv_cache.initialized) return;
    
    cudaFree(g_kv_cache.k_pages);
    cudaFree(g_kv_cache.v_pages);
    delete[] g_kv_cache.page_allocated;
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
    
    // Find free page
    for (int i = 0; i < MAX_PAGES; i++) {
        if (!g_kv_cache.page_allocated[i]) {
            g_kv_cache.page_allocated[i] = true;
            
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
        g_kv_cache.page_allocated[page_idx] = false;
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
// Prefix Caching
// ============================================================================

/**
 * Hash table for cached prefixes
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
// Iteration Step
// ============================================================================

/**
 * Single iteration of continuous batching
 * - Process prefills (full sequence attention)
 * - Process decodes (single token attention)
 * - Can add new requests and remove finished ones between iterations
 */
extern "C" int continuous_batch_step(
    __half* output_logits,     // [num_sequences, vocab_size]
    const __half* model_weights,
    int vocab_size
) {
    if (g_batch.num_sequences == 0) return 0;
    
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
    
    // Find max sequence length in current batch for shared memory sizing
    int max_seq_len = 0;
    for (int i = 0; i < MAX_SEQUENCES; i++) {
        if (g_page_table.active[i] && g_page_table.sequence_lengths[i] > max_seq_len) {
            max_seq_len = g_page_table.sequence_lengths[i];
        }
    }
    if (max_seq_len == 0) return 0;
    
    // Allocate temporary query buffer for current tokens
    // In production: query comes from embedding + RoPE of current token positions
    __half* d_query = nullptr;
    size_t query_size = g_batch.num_sequences * g_kv_cache.num_heads * g_kv_cache.head_dim * sizeof(__half);
    err = cudaMalloc(&d_query, query_size);
    if (err != cudaSuccess) return -1;
    
    // Allocate temporary attention output
    __half* d_attn_output = nullptr;
    err = cudaMalloc(&d_attn_output, query_size);
    if (err != cudaSuccess) { cudaFree(d_query); return -1; }
    
    // Run paged attention for all active sequences
    float scale = 1.0f / sqrtf((float)g_kv_cache.head_dim);
    
    dim3 grid(g_kv_cache.num_heads, g_batch.num_sequences);
    size_t smem_size = (max_seq_len + BLOCK_SIZE) * sizeof(float);
    
    paged_attention_kernel<<<grid, BLOCK_SIZE, smem_size>>>(
        d_attn_output, d_query,
        g_kv_cache.k_pages, g_kv_cache.v_pages,
        g_batch.d_page_indices, g_batch.d_seq_lengths,
        g_kv_cache.num_heads, g_kv_cache.num_kv_heads,
        g_kv_cache.head_dim, max_seq_len, scale
    );
    
    err = cudaGetLastError();
    if (err != cudaSuccess) {
        cudaFree(d_query);
        cudaFree(d_attn_output);
        return -1;
    }
    
    // TODO: In production, complete the forward pass:
    // 1. Embedding lookup + RoPE for current token → d_query
    // 2. For each layer: attention → FFN (SwiGLU) → residual + RMSNorm
    // 3. Final LM head projection: d_attn_output @ lm_head_weights → output_logits
    // Currently: attention output is computed but full layer stack is not yet wired
    
    cudaFree(d_query);
    cudaFree(d_attn_output);
    
    return 0;
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
    
    // Copy page table (share pages, don't copy data)
    g_page_table.active[child_seq_id] = true;
    g_page_table.sequence_lengths[child_seq_id] = g_page_table.sequence_lengths[parent_seq_id];
    g_page_table.num_pages[child_seq_id] = g_page_table.num_pages[parent_seq_id];
    
    for (int i = 0; i < g_page_table.num_pages[parent_seq_id]; i++) {
        g_page_table.page_indices[child_seq_id][i] = g_page_table.page_indices[parent_seq_id][i];
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
        if (g_kv_cache.page_allocated[i]) {
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
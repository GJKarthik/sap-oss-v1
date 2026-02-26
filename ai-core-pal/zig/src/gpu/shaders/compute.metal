// ANWID Metal Compute Shaders
// GPU kernels for inference workloads on Apple Silicon
// Compile: xcrun -sdk macosx metal -c compute.metal -o compute.air
//          xcrun -sdk macosx metallib compute.air -o compute.metallib

#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Constants
// ============================================================================

constant float EPS = 1e-5f;

// ============================================================================
// JSON Field Extraction Kernel
// ============================================================================

/// Parallel pattern search for "prompt"/"input" key in JSON bytes.
/// Each thread scans a 256-byte chunk. First match wins via atomic CAS.
kernel void json_find_key(
    device const uint8_t*  data       [[buffer(0)]],
    device atomic_uint*    result     [[buffer(1)]],
    constant uint32_t&     data_len   [[buffer(2)]],
    uint                   tid        [[thread_position_in_grid]])
{
    const uint chunk = 256;
    const uint start = tid * chunk;
    if (start >= data_len) return;
    const uint end = min(start + chunk + 20, data_len);

    // Pattern: "prompt": "  (11 bytes)
    const uint8_t pat_prompt[11] = {'"','p','r','o','m','p','t','"',':',' ','"'};
    // Pattern: "input": "   (10 bytes)
    const uint8_t pat_input[10] = {'"','i','n','p','u','t','"',':',' ','"'};

    for (uint i = start; i + 10 <= end; i++) {
        if (i + 11 <= end) {
            bool match_prompt = true;
            for (uint j = 0; j < 11; j++) {
                if (data[i + j] != pat_prompt[j]) { match_prompt = false; break; }
            }
            if (match_prompt) {
                uint text_start = i + 11;
                uint text_end = text_start;
                bool in_escape = false;
                while (text_end < data_len) {
                    if (in_escape) { in_escape = false; text_end++; continue; }
                    if (data[text_end] == '\\') { in_escape = true; text_end++; continue; }
                    if (data[text_end] == '"') break;
                    text_end++;
                }
                uint expected = 0;
                if (atomic_compare_exchange_weak_explicit(&result[2], &expected, 1,
                        memory_order_relaxed, memory_order_relaxed)) {
                    atomic_store_explicit(&result[0], text_start, memory_order_relaxed);
                    atomic_store_explicit(&result[1], text_end,   memory_order_relaxed);
                }
                return;
            }
        }

        bool match_input = true;
        for (uint j = 0; j < 10; j++) {
            if (data[i + j] != pat_input[j]) { match_input = false; break; }
        }
        if (match_input) {
            uint text_start = i + 10;
            uint text_end = text_start;
            bool in_escape = false;
            while (text_end < data_len) {
                if (in_escape) { in_escape = false; text_end++; continue; }
                if (data[text_end] == '\\') { in_escape = true; text_end++; continue; }
                if (data[text_end] == '"') break;
                text_end++;
            }
            uint expected = 0;
            if (atomic_compare_exchange_weak_explicit(&result[2], &expected, 1,
                    memory_order_relaxed, memory_order_relaxed)) {
                atomic_store_explicit(&result[0], text_start, memory_order_relaxed);
                atomic_store_explicit(&result[1], text_end,   memory_order_relaxed);
            }
            return;
        }
    }
}

// ============================================================================
// GPU Tokenization Kernel
// ============================================================================

/// Per-character token boundary detection with atomic slot claiming.
kernel void gpu_tokenize_bytes(
    device const uint8_t*  text        [[buffer(0)]],
    device uint32_t*       tokens      [[buffer(1)]],
    device atomic_uint*    token_count [[buffer(2)]],
    constant uint32_t&     text_len    [[buffer(3)]],
    constant uint32_t&     max_tokens  [[buffer(4)]],
    uint                   tid         [[thread_position_in_grid]])
{
    if (tid >= text_len) return;
    uint8_t c = text[tid];

    bool is_boundary = (c == ' ' || c == '\n' || c == '\t' ||
                        c == '.' || c == ',' || c == '!' || c == '?' ||
                        c == ';' || c == ':' || c == '"' || c == '\'' ||
                        c == '(' || c == ')' || c == '[' || c == ']' ||
                        c == '{' || c == '}');

    if (is_boundary || tid == 0) {
        uint slot = atomic_fetch_add_explicit(token_count, 1, memory_order_relaxed);
        if (slot < max_tokens) {
            tokens[slot] = (uint32_t)c + 4;
        }
    }
}

// ============================================================================
// Vector Operations
// ============================================================================

/// Vector addition: c = a + b
kernel void vector_add(
    device const float* a [[buffer(0)]],
    device const float* b [[buffer(1)]],
    device float* c [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    c[id] = a[id] + b[id];
}

/// Vector scale: b = a * scale
kernel void vector_scale(
    device const float* a [[buffer(0)]],
    device float* b [[buffer(1)]],
    constant float& scale [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    b[id] = a[id] * scale;
}

/// Element-wise multiply: c = a * b
kernel void vector_mul(
    device const float* a [[buffer(0)]],
    device const float* b [[buffer(1)]],
    device float* c [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    c[id] = a[id] * b[id];
}

// ============================================================================
// Embedding Lookup
// ============================================================================

/// Embedding lookup with vocabulary
/// input: token indices (uint32)
/// embedding_table: [vocab_size x embedding_dim]
/// output: [batch_size x embedding_dim]
kernel void embedding_lookup(
    device const uint* input_tokens [[buffer(0)]],
    device const float* embedding_table [[buffer(1)]],
    device float* output [[buffer(2)]],
    constant uint& embedding_dim [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint batch_idx = gid.y;
    uint dim_idx = gid.x;
    
    uint token = input_tokens[batch_idx];
    output[batch_idx * embedding_dim + dim_idx] = embedding_table[token * embedding_dim + dim_idx];
}

// ============================================================================
// Matrix Multiplication
// ============================================================================

/// Simple matrix multiply: C = A @ B
/// A: [M x K], B: [K x N], C: [M x N]
kernel void matmul_naive(
    device const float* A [[buffer(0)]],
    device const float* B [[buffer(1)]],
    device float* C [[buffer(2)]],
    constant uint& M [[buffer(3)]],
    constant uint& N [[buffer(4)]],
    constant uint& K [[buffer(5)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint row = gid.y;
    uint col = gid.x;
    
    if (row >= M || col >= N) return;
    
    float sum = 0.0f;
    for (uint k = 0; k < K; k++) {
        sum += A[row * K + k] * B[k * N + col];
    }
    C[row * N + col] = sum;
}

/// Tiled matrix multiply for better cache utilization
/// Uses threadgroup memory for shared data
kernel void matmul_tiled(
    device const float* A [[buffer(0)]],
    device const float* B [[buffer(1)]],
    device float* C [[buffer(2)]],
    constant uint& M [[buffer(3)]],
    constant uint& N [[buffer(4)]],
    constant uint& K [[buffer(5)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 tid [[thread_position_in_threadgroup]],
    uint2 tgSize [[threads_per_threadgroup]]
) {
    // Tile size (should match threadgroup size)
    constexpr uint TILE_SIZE = 16;
    
    threadgroup float As[TILE_SIZE][TILE_SIZE];
    threadgroup float Bs[TILE_SIZE][TILE_SIZE];
    
    uint row = gid.y;
    uint col = gid.x;
    
    float sum = 0.0f;
    
    // Loop over tiles
    for (uint t = 0; t < (K + TILE_SIZE - 1) / TILE_SIZE; t++) {
        // Load tile of A into shared memory
        uint aRow = row;
        uint aCol = t * TILE_SIZE + tid.x;
        if (aRow < M && aCol < K) {
            As[tid.y][tid.x] = A[aRow * K + aCol];
        } else {
            As[tid.y][tid.x] = 0.0f;
        }
        
        // Load tile of B into shared memory
        uint bRow = t * TILE_SIZE + tid.y;
        uint bCol = col;
        if (bRow < K && bCol < N) {
            Bs[tid.y][tid.x] = B[bRow * N + bCol];
        } else {
            Bs[tid.y][tid.x] = 0.0f;
        }
        
        threadgroup_barrier(mem_flags::mem_threadgroup);
        
        // Compute partial dot product
        for (uint k = 0; k < TILE_SIZE; k++) {
            sum += As[tid.y][k] * Bs[k][tid.x];
        }
        
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    
    if (row < M && col < N) {
        C[row * N + col] = sum;
    }
}

// ============================================================================
// Softmax
// ============================================================================

/// Softmax per row: output[i] = exp(input[i] - max) / sum(exp(input - max))
/// Uses two-pass algorithm for numerical stability
kernel void softmax_row(
    device const float* input [[buffer(0)]],
    device float* output [[buffer(1)]],
    constant uint& seq_len [[buffer(2)]],
    uint batch_idx [[thread_position_in_grid]]
) {
    uint offset = batch_idx * seq_len;
    
    // Pass 1: Find max
    float max_val = input[offset];
    for (uint i = 1; i < seq_len; i++) {
        max_val = max(max_val, input[offset + i]);
    }
    
    // Pass 2: Compute exp and sum
    float sum = 0.0f;
    for (uint i = 0; i < seq_len; i++) {
        float exp_val = exp(input[offset + i] - max_val);
        output[offset + i] = exp_val;
        sum += exp_val;
    }
    
    // Pass 3: Normalize
    float inv_sum = 1.0f / sum;
    for (uint i = 0; i < seq_len; i++) {
        output[offset + i] *= inv_sum;
    }
}

/// Parallel softmax using threadgroup reduction
kernel void softmax_parallel(
    device const float* input [[buffer(0)]],
    device float* output [[buffer(1)]],
    constant uint& seq_len [[buffer(2)]],
    uint batch_idx [[threadgroup_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]],
    uint tg_size [[threads_per_threadgroup]]
) {
    threadgroup float shared_max[256];
    threadgroup float shared_sum[256];
    
    uint offset = batch_idx * seq_len;
    
    // Step 1: Find local max
    float local_max = -INFINITY;
    for (uint i = tid; i < seq_len; i += tg_size) {
        local_max = max(local_max, input[offset + i]);
    }
    shared_max[tid] = local_max;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    // Reduce to find global max
    for (uint s = tg_size / 2; s > 0; s >>= 1) {
        if (tid < s) {
            shared_max[tid] = max(shared_max[tid], shared_max[tid + s]);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    float max_val = shared_max[0];
    
    // Step 2: Compute exp and local sum
    float local_sum = 0.0f;
    for (uint i = tid; i < seq_len; i += tg_size) {
        float exp_val = exp(input[offset + i] - max_val);
        output[offset + i] = exp_val;
        local_sum += exp_val;
    }
    shared_sum[tid] = local_sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    // Reduce to find global sum
    for (uint s = tg_size / 2; s > 0; s >>= 1) {
        if (tid < s) {
            shared_sum[tid] += shared_sum[tid + s];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    float total_sum = shared_sum[0];
    
    // Step 3: Normalize
    float inv_sum = 1.0f / total_sum;
    for (uint i = tid; i < seq_len; i += tg_size) {
        output[offset + i] *= inv_sum;
    }
}

// ============================================================================
// Layer Normalization
// ============================================================================

/// Layer norm: y = (x - mean) / sqrt(var + eps) * gamma + beta
kernel void layer_norm(
    device const float* input [[buffer(0)]],
    device float* output [[buffer(1)]],
    device const float* gamma [[buffer(2)]],
    device const float* beta [[buffer(3)]],
    constant uint& hidden_size [[buffer(4)]],
    uint batch_idx [[thread_position_in_grid]]
) {
    uint offset = batch_idx * hidden_size;
    
    // Compute mean
    float mean = 0.0f;
    for (uint i = 0; i < hidden_size; i++) {
        mean += input[offset + i];
    }
    mean /= float(hidden_size);
    
    // Compute variance
    float var = 0.0f;
    for (uint i = 0; i < hidden_size; i++) {
        float diff = input[offset + i] - mean;
        var += diff * diff;
    }
    var /= float(hidden_size);
    
    // Normalize and scale
    float inv_std = rsqrt(var + EPS);
    for (uint i = 0; i < hidden_size; i++) {
        float normalized = (input[offset + i] - mean) * inv_std;
        output[offset + i] = normalized * gamma[i] + beta[i];
    }
}

/// Layer norm without affine transformation (no gamma/beta)
kernel void layer_norm_simple(
    device const float* input [[buffer(0)]],
    device float* output [[buffer(1)]],
    constant uint& hidden_size [[buffer(2)]],
    uint batch_idx [[thread_position_in_grid]]
) {
    uint offset = batch_idx * hidden_size;
    
    // Compute mean
    float mean = 0.0f;
    for (uint i = 0; i < hidden_size; i++) {
        mean += input[offset + i];
    }
    mean /= float(hidden_size);
    
    // Compute variance
    float var = 0.0f;
    for (uint i = 0; i < hidden_size; i++) {
        float diff = input[offset + i] - mean;
        var += diff * diff;
    }
    var /= float(hidden_size);
    
    // Normalize
    float inv_std = rsqrt(var + EPS);
    for (uint i = 0; i < hidden_size; i++) {
        output[offset + i] = (input[offset + i] - mean) * inv_std;
    }
}

// ============================================================================
// Cosine Similarity
// ============================================================================

/// Cosine similarity between query and document vectors
/// query: [embedding_dim]
/// documents: [num_docs x embedding_dim]  
/// scores: [num_docs]
kernel void cosine_similarity(
    device const float* query [[buffer(0)]],
    device const float* documents [[buffer(1)]],
    device float* scores [[buffer(2)]],
    constant uint& embedding_dim [[buffer(3)]],
    uint doc_idx [[thread_position_in_grid]]
) {
    float dot = 0.0f;
    float query_norm = 0.0f;
    float doc_norm = 0.0f;
    
    uint doc_offset = doc_idx * embedding_dim;
    
    for (uint i = 0; i < embedding_dim; i++) {
        float q = query[i];
        float d = documents[doc_offset + i];
        dot += q * d;
        query_norm += q * q;
        doc_norm += d * d;
    }
    
    float denom = sqrt(query_norm) * sqrt(doc_norm);
    scores[doc_idx] = (denom > 0.0f) ? (dot / denom) : 0.0f;
}

/// Batch cosine similarity: multiple queries against multiple documents
/// queries: [num_queries x embedding_dim]
/// documents: [num_docs x embedding_dim]
/// scores: [num_queries x num_docs]
kernel void cosine_similarity_batch(
    device const float* queries [[buffer(0)]],
    device const float* documents [[buffer(1)]],
    device float* scores [[buffer(2)]],
    constant uint& embedding_dim [[buffer(3)]],
    constant uint& num_docs [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint query_idx = gid.y;
    uint doc_idx = gid.x;
    
    float dot = 0.0f;
    float query_norm = 0.0f;
    float doc_norm = 0.0f;
    
    uint query_offset = query_idx * embedding_dim;
    uint doc_offset = doc_idx * embedding_dim;
    
    for (uint i = 0; i < embedding_dim; i++) {
        float q = queries[query_offset + i];
        float d = documents[doc_offset + i];
        dot += q * d;
        query_norm += q * q;
        doc_norm += d * d;
    }
    
    float denom = sqrt(query_norm) * sqrt(doc_norm);
    scores[query_idx * num_docs + doc_idx] = (denom > 0.0f) ? (dot / denom) : 0.0f;
}

// ============================================================================
// ReLU / GELU Activation
// ============================================================================

kernel void relu(
    device const float* input [[buffer(0)]],
    device float* output [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    output[id] = max(input[id], 0.0f);
}

/// GELU activation: 0.5 * x * (1 + tanh(sqrt(2/pi) * (x + 0.044715 * x^3)))
kernel void gelu(
    device const float* input [[buffer(0)]],
    device float* output [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    float x = input[id];
    float x3 = x * x * x;
    float inner = 0.7978845608f * (x + 0.044715f * x3);  // sqrt(2/pi) ≈ 0.7978845608
    output[id] = 0.5f * x * (1.0f + tanh(inner));
}

// ============================================================================
// Attention
// ============================================================================

/// Scaled dot-product attention (single head)
/// Q: [seq_len x head_dim]
/// K: [seq_len x head_dim]
/// V: [seq_len x head_dim]
/// output: [seq_len x head_dim]
kernel void attention_single_head(
    device const float* Q [[buffer(0)]],
    device const float* K [[buffer(1)]],
    device const float* V [[buffer(2)]],
    device float* output [[buffer(3)]],
    device float* attn_weights [[buffer(4)]],
    constant uint& seq_len [[buffer(5)]],
    constant uint& head_dim [[buffer(6)]],
    uint query_idx [[thread_position_in_grid]]
) {
    float scale = rsqrt(float(head_dim));
    
    // Compute attention scores: Q[query_idx] @ K^T
    float max_score = -INFINITY;
    for (uint k = 0; k < seq_len; k++) {
        float score = 0.0f;
        for (uint d = 0; d < head_dim; d++) {
            score += Q[query_idx * head_dim + d] * K[k * head_dim + d];
        }
        score *= scale;
        attn_weights[query_idx * seq_len + k] = score;
        max_score = max(max_score, score);
    }
    
    // Softmax
    float sum = 0.0f;
    for (uint k = 0; k < seq_len; k++) {
        float w = exp(attn_weights[query_idx * seq_len + k] - max_score);
        attn_weights[query_idx * seq_len + k] = w;
        sum += w;
    }
    
    float inv_sum = 1.0f / sum;
    for (uint k = 0; k < seq_len; k++) {
        attn_weights[query_idx * seq_len + k] *= inv_sum;
    }
    
    // Weighted sum of V
    for (uint d = 0; d < head_dim; d++) {
        float weighted_sum = 0.0f;
        for (uint k = 0; k < seq_len; k++) {
            weighted_sum += attn_weights[query_idx * seq_len + k] * V[k * head_dim + d];
        }
        output[query_idx * head_dim + d] = weighted_sum;
    }
}
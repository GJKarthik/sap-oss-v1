/**
 * Kimi2.5 Model-Specific CUDA Kernels
 *
 * Optimizations for Moonshot Kimi2.5 long-context architecture:
 * - Sliding Window Attention with configurable window
 * - YaRN RoPE scaling for 128K+ context
 * - Fused GQA with 4:1 Q/KV ratio
 * - Efficient causal + window mask computation
 */

#include "cuda_kernels.h"
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <cmath>
#include <cfloat>

// ============================================================================
// Constants for Kimi2.5
// ============================================================================

#define BLOCK_SIZE 256
#define WARP_SIZE 32
#define NUM_WARPS (BLOCK_SIZE / WARP_SIZE)

#define KIMI25_DEFAULT_WINDOW 4096
#define KIMI25_NUM_Q_HEADS 32
#define KIMI25_NUM_KV_HEADS 8
#define KIMI25_HEAD_DIM 128
#define KIMI25_Q_PER_KV (KIMI25_NUM_Q_HEADS / KIMI25_NUM_KV_HEADS)

#define TILE_Q 64
#define TILE_K 64

// ============================================================================
// YaRN RoPE Kernel
// ============================================================================

/**
 * YaRN-extended RoPE for long-context scaling.
 * Applies frequency scaling with NTK-aware interpolation.
 * 
 * For each dimension i:
 *   - Low frequencies (i < threshold): scaled by scale_factor
 *   - High frequencies (i >= threshold): interpolated smoothly
 *   - theta_scaled = theta * (scale ** (2i/d))
 */
__global__ void kimi25_yarn_rope_kernel(
    float* __restrict__ query,
    float* __restrict__ key,
    const int batch_size,
    const int seq_len,
    const int num_q_heads,
    const int num_kv_heads,
    const int head_dim,
    const float theta_base,
    const float scale_factor,
    const float yarn_attn_factor
) {
    int batch_idx = blockIdx.z;
    int head_idx = blockIdx.y;
    int pos = blockIdx.x;
    int dim_idx = threadIdx.x;
    
    if (pos >= seq_len || dim_idx >= head_dim / 2) return;
    
    // Compute frequency for this dimension
    float freq = 1.0f / powf(theta_base, (float)(2 * dim_idx) / (float)head_dim);
    
    // YaRN scaling: apply scale_factor to low frequencies
    float threshold = (float)head_dim * 0.75f;  // Scale low 75% of frequencies
    float scaled_freq = freq;
    
    if (dim_idx < threshold) {
        // Low frequency: apply NTK-aware scaling
        float scale_exp = (float)(2 * dim_idx) / (float)head_dim;
        scaled_freq = freq * powf(scale_factor, scale_exp);
    } else {
        // High frequency: smooth interpolation
        float alpha = ((float)dim_idx - threshold) / ((float)head_dim * 0.25f);
        alpha = fminf(1.0f, fmaxf(0.0f, alpha));
        float scaled_low = freq * powf(scale_factor, 1.0f);
        scaled_freq = freq + alpha * (scaled_low - freq);
    }
    
    float theta = (float)pos * scaled_freq;
    float cos_t = cosf(theta);
    float sin_t = sinf(theta);
    
    // Apply rotation to query
    int q_offset = ((batch_idx * num_q_heads + head_idx) * seq_len + pos) * head_dim;
    float q0 = query[q_offset + 2 * dim_idx];
    float q1 = query[q_offset + 2 * dim_idx + 1];
    query[q_offset + 2 * dim_idx] = q0 * cos_t - q1 * sin_t;
    query[q_offset + 2 * dim_idx + 1] = q0 * sin_t + q1 * cos_t;
    
    // Apply rotation to key
    int k_offset = ((batch_idx * num_kv_heads + (head_idx / KIMI25_Q_PER_KV)) * seq_len + pos) * head_dim;
    float k0 = key[k_offset + 2 * dim_idx];
    float k1 = key[k_offset + 2 * dim_idx + 1];
    key[k_offset + 2 * dim_idx] = k0 * cos_t - k1 * sin_t;
    key[k_offset + 2 * dim_idx + 1] = k0 * sin_t + k1 * cos_t;
}

// ============================================================================
// Sliding Window Attention Kernel
// ============================================================================

/**
 * Sliding Window Attention (SWA) for efficient long-context processing.
 * Each query attends only to keys within [max(0, q - window_size), q].
 * Uses online softmax for memory efficiency.
 */
__global__ void kimi25_sliding_window_attention_kernel(
    float* __restrict__ output,
    const float* __restrict__ query,
    const float* __restrict__ key,
    const float* __restrict__ value,
    const int batch_size,
    const int seq_len,
    const int num_q_heads,
    const int num_kv_heads,
    const int head_dim,
    const int window_size,
    const float scale,
    const bool causal
) {
    extern __shared__ float smem[];
    float* q_tile = smem;
    float* k_tile = smem + TILE_Q * head_dim;
    float* v_tile = smem + TILE_Q * head_dim + TILE_K * head_dim;
    
    int batch_idx = blockIdx.z;
    int q_head_idx = blockIdx.y;
    int q_block_idx = blockIdx.x;
    int tid = threadIdx.x;
    
    int q_start = q_block_idx * TILE_Q;
    int q_end = min(q_start + TILE_Q, seq_len);
    
    // Load query tile to shared memory
    for (int i = tid; i < (q_end - q_start) * head_dim; i += BLOCK_SIZE) {
        int q_pos = q_start + i / head_dim;
        int dim = i % head_dim;
        int q_offset = ((batch_idx * num_q_heads + q_head_idx) * seq_len + q_pos) * head_dim;
        q_tile[i] = query[q_offset + dim];
    }
    __syncthreads();
    
    // Compute attention for each query position
    for (int q_pos = q_start; q_pos < q_end; q_pos++) {
        int q_local = q_pos - q_start;
        
        // Initialize accumulators
        float max_val = -FLT_MAX;
        float sum_exp = 0.0f;
        float acc[KIMI25_HEAD_DIM] = {0.0f};
        
        // Determine key range for this query (sliding window + causal)
        int k_start = max(0, q_pos - window_size);
        int k_end = causal ? q_pos + 1 : seq_len;
        
        // Process key tiles
        for (int k_block = 0; k_block < (seq_len + TILE_K - 1) / TILE_K; k_block++) {
            int k_tile_start = k_block * TILE_K;
            int k_tile_end = min(k_tile_start + TILE_K, seq_len);
            
            // Skip tiles outside window
            if (k_tile_end <= k_start || k_tile_start >= k_end) continue;
            
            // Load K, V tiles
            int kv_head_idx = q_head_idx / KIMI25_Q_PER_KV;
            for (int i = tid; i < (k_tile_end - k_tile_start) * head_dim; i += BLOCK_SIZE) {
                int k_pos = k_tile_start + i / head_dim;
                int dim = i % head_dim;
                int k_offset = ((batch_idx * num_kv_heads + kv_head_idx) * seq_len + k_pos) * head_dim;
                k_tile[i] = key[k_offset + dim];
                v_tile[i] = value[k_offset + dim];
            }
            __syncthreads();
            
            // Compute attention scores for this tile
            for (int k_pos = k_tile_start; k_pos < k_tile_end; k_pos++) {
                if (k_pos < k_start || k_pos >= k_end) continue;
                
                int k_local = k_pos - k_tile_start;
                
                // Compute Q @ K^T
                float score = 0.0f;
                for (int d = 0; d < head_dim; d++) {
                    score += q_tile[q_local * head_dim + d] * k_tile[k_local * head_dim + d];
                }
                score *= scale;
                
                // Online softmax: update max
                float new_max = fmaxf(max_val, score);
                float exp_diff = expf(max_val - new_max);
                sum_exp = sum_exp * exp_diff + expf(score - new_max);
                max_val = new_max;
                
                // Accumulate weighted value
                float weight = expf(score - max_val);
                for (int d = 0; d < head_dim; d++) {
                    acc[d] = acc[d] * exp_diff + weight * v_tile[k_local * head_dim + d];
                }
            }
            __syncthreads();
        }
        
        // Normalize and write output
        float norm = 1.0f / (sum_exp + 1e-8f);
        int out_offset = ((batch_idx * num_q_heads + q_head_idx) * seq_len + q_pos) * head_dim;
        for (int d = tid; d < head_dim; d += BLOCK_SIZE) {
            output[out_offset + d] = acc[d] * norm;
        }
    }
}

// ============================================================================
// Grouped Query Attention Kernel
// ============================================================================

/**
 * Fused GQA with sliding window mask.
 * 32 Q heads share 8 KV heads (4:1 ratio).
 */
__global__ void kimi25_gqa_forward_kernel(
    float* __restrict__ output,
    const float* __restrict__ query,
    const float* __restrict__ key,
    const float* __restrict__ value,
    const int batch_size,
    const int seq_len,
    const int window_size,
    const float scale
) {
    int batch_idx = blockIdx.z;
    int q_head_idx = blockIdx.y;
    int q_pos = blockIdx.x;
    int tid = threadIdx.x;
    
    int kv_head_idx = q_head_idx / KIMI25_Q_PER_KV;
    
    // Load query
    float q_val[KIMI25_HEAD_DIM];
    for (int d = tid; d < KIMI25_HEAD_DIM; d += BLOCK_SIZE) {
        int q_offset = ((batch_idx * KIMI25_NUM_Q_HEADS + q_head_idx) * seq_len + q_pos) * KIMI25_HEAD_DIM;
        q_val[d] = query[q_offset + d];
    }
    __syncthreads();
    
    // Compute attention
    float max_val = -FLT_MAX;
    float sum_exp = 0.0f;
    float acc[KIMI25_HEAD_DIM] = {0.0f};
    
    int k_start = max(0, q_pos - window_size);
    int k_end = q_pos + 1;
    
    for (int k_pos = k_start; k_pos < k_end; k_pos++) {
        // Compute score
        float score = 0.0f;
        for (int d = tid; d < KIMI25_HEAD_DIM; d += BLOCK_SIZE) {
            int k_offset = ((batch_idx * KIMI25_NUM_KV_HEADS + kv_head_idx) * seq_len + k_pos) * KIMI25_HEAD_DIM;
            score += q_val[d] * key[k_offset + d];
        }
        
        // Warp reduce
        for (int offset = WARP_SIZE / 2; offset > 0; offset /= 2) {
            score += __shfl_down_sync(0xffffffff, score, offset);
        }
        
        if (tid == 0) {
            score *= scale;
            float new_max = fmaxf(max_val, score);
            float exp_diff = expf(max_val - new_max);
            sum_exp = sum_exp * exp_diff + expf(score - new_max);
            max_val = new_max;
        }
        __syncthreads();
    }
    
    // Normalize and write
    float norm = 1.0f / (sum_exp + 1e-8f);
    int out_offset = ((batch_idx * KIMI25_NUM_Q_HEADS + q_head_idx) * seq_len + q_pos) * KIMI25_HEAD_DIM;
    for (int d = tid; d < KIMI25_HEAD_DIM; d += BLOCK_SIZE) {
        output[out_offset + d] = acc[d] * norm;
    }
}

// ============================================================================
// Fused SiLU + Multiply Kernel
// ============================================================================

/**
 * Fused SiLU activation with elementwise multiply.
 * silu(x) = x * sigmoid(x)
 * output = silu(gate) * up
 */
__global__ void kimi25_silu_mul_kernel(
    float* __restrict__ output,
    const float* __restrict__ gate,
    const float* __restrict__ up,
    const int total_elements
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    
    if (idx < total_elements) {
        float g = gate[idx];
        float silu_g = g / (1.0f + expf(-g));
        output[idx] = silu_g * up[idx];
    }
}

// ============================================================================
// Extern C Wrappers
// ============================================================================

extern "C" int kimi25_yarn_rope_forward(
    float* query, float* key,
    int batch_size, int seq_len, int num_q_heads, int num_kv_heads, int head_dim,
    float theta_base, float scale_factor, float yarn_attn_factor
) {
    if (!query || !key) return -1;
    
    dim3 grid((seq_len + TILE_Q - 1) / TILE_Q, num_q_heads, batch_size);
    dim3 block(BLOCK_SIZE);
    
    kimi25_yarn_rope_kernel<<<grid, block>>>(
        query, key,
        batch_size, seq_len, num_q_heads, num_kv_heads, head_dim,
        theta_base, scale_factor, yarn_attn_factor
    );
    
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

extern "C" int kimi25_swa_forward(
    float* output, const float* query, const float* key, const float* value,
    int batch_size, int seq_len, int num_q_heads, int num_kv_heads, int head_dim,
    int window_size, float scale, int causal
) {
    if (!output || !query || !key || !value) return -1;
    
    int num_q_blocks = (seq_len + TILE_Q - 1) / TILE_Q;
    dim3 grid(num_q_blocks, num_q_heads, batch_size);
    dim3 block(BLOCK_SIZE);
    
    size_t smem_size = (TILE_Q + TILE_K * 2) * head_dim * sizeof(float);
    
    kimi25_sliding_window_attention_kernel<<<grid, block, smem_size>>>(
        output, query, key, value,
        batch_size, seq_len, num_q_heads, num_kv_heads, head_dim,
        window_size, scale, causal != 0
    );
    
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

extern "C" int kimi25_gqa_forward(
    float* output, const float* query, const float* key, const float* value,
    int batch_size, int seq_len, int window_size, float scale
) {
    if (!output || !query || !key || !value) return -1;
    
    dim3 grid(seq_len, KIMI25_NUM_Q_HEADS, batch_size);
    dim3 block(BLOCK_SIZE);
    
    kimi25_gqa_forward_kernel<<<grid, block>>>(
        output, query, key, value,
        batch_size, seq_len, window_size, scale
    );
    
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

extern "C" int kimi25_silu_mul_forward(
    float* output, const float* gate, const float* up,
    int batch_size, int seq_len, int hidden_dim
) {
    if (!output || !gate || !up) return -1;
    
    int total_elements = batch_size * seq_len * hidden_dim;
    int threads = 256;
    int blocks = (total_elements + threads - 1) / threads;
    
    kimi25_silu_mul_kernel<<<blocks, threads>>>(
        output, gate, up, total_elements
    );
    
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}


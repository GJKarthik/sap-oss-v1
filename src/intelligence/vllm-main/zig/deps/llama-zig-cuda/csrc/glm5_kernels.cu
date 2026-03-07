/**
 * ChatGLM5 Model-Specific CUDA Kernels
 *
 * Optimizations for ChatGLM5 architecture:
 * - Fused Multi-Query Attention with 16:1 Q/KV ratio (32 Q heads, 2 KV heads)
 * - GLM-style RoPE (interleaved half-rotary: first 64 dims rotated, second 64 passthrough)
 * - Fused SwiGLU FFN activation (gate * silu(up))
 * - RMSNorm with FP32 accumulation
 * - Vocabulary size: 151,552 (large Chinese token set)
 */

#include "cuda_kernels.h"
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <cmath>
#include <cfloat>

// ============================================================================
// Constants
// ============================================================================

#define BLOCK_SIZE 256
#define WARP_SIZE 32
#define GLM5_NUM_Q_HEADS 32
#define GLM5_NUM_KV_HEADS 2
#define GLM5_HEAD_DIM 128
#define GLM5_ROPE_DIM 64  // Half-rotary: only first 64 dims get RoPE

// ============================================================================
// GLM5 RoPE Kernel (Half-Rotary Position Embedding)
// ============================================================================

/**
 * GLM-style RoPE: Apply rotary embeddings only to first ROPE_DIM dimensions.
 * Pattern: (x0,x1) → (x0*cos(θ) - x1*sin(θ), x0*sin(θ) + x1*cos(θ))
 * Second half of dimensions pass through unchanged.
 *
 * Grid: (seq_len, num_heads, batch_size)
 * Block: (BLOCK_SIZE)
 */
__global__ void glm5_rope_kernel(
    float* __restrict__ query,      // [batch, num_q_heads, seq_len, head_dim]
    float* __restrict__ key,        // [batch, num_kv_heads, seq_len, head_dim]
    const int batch_size,
    const int seq_len,
    const int num_q_heads,
    const int num_kv_heads,
    const int head_dim,
    const int rope_dim,
    const float theta_base
) {
    int pos = blockIdx.x;  // sequence position
    int head_idx = blockIdx.y;
    int batch_idx = blockIdx.z;
    int tid = threadIdx.x;
    
    if (pos >= seq_len) return;
    
    // Process query heads
    if (head_idx < num_q_heads) {
        int offset = ((batch_idx * num_q_heads + head_idx) * seq_len + pos) * head_dim;
        
        for (int d = tid; d < rope_dim; d += BLOCK_SIZE) {
            // Compute rotation angle: θ_d = θ_base^(-2d/rope_dim)
            float inv_freq = 1.0f / powf(theta_base, 2.0f * d / rope_dim);
            float angle = pos * inv_freq;
            float cos_a = cosf(angle);
            float sin_a = sinf(angle);
            
            // Interleaved pattern: pairs (x0, x1) at positions (2d, 2d+1)
            int idx0 = 2 * d;
            int idx1 = 2 * d + 1;
            
            if (idx1 < head_dim) {
                float x0 = query[offset + idx0];
                float x1 = query[offset + idx1];
                query[offset + idx0] = x0 * cos_a - x1 * sin_a;
                query[offset + idx1] = x0 * sin_a + x1 * cos_a;
            }
        }
    }
    
    // Process KV heads (same RoPE application)
    if (head_idx < num_kv_heads) {
        int offset = ((batch_idx * num_kv_heads + head_idx) * seq_len + pos) * head_dim;
        
        for (int d = tid; d < rope_dim; d += BLOCK_SIZE) {
            float inv_freq = 1.0f / powf(theta_base, 2.0f * d / rope_dim);
            float angle = pos * inv_freq;
            float cos_a = cosf(angle);
            float sin_a = sinf(angle);
            
            int idx0 = 2 * d;
            int idx1 = 2 * d + 1;
            
            if (idx1 < head_dim) {
                float x0 = key[offset + idx0];
                float x1 = key[offset + idx1];
                key[offset + idx0] = x0 * cos_a - x1 * sin_a;
                key[offset + idx1] = x0 * sin_a + x1 * cos_a;
            }
        }
    }
}

// ============================================================================
// GLM5 Multi-Query Attention Kernel
// ============================================================================

/**
 * Fused MQA: 32 Q heads share 2 KV heads (16:1 ratio).
 * Mapping: kv_head = q_head / (num_q_heads / num_kv_heads) = q_head / 16
 *
 * Tiled computation: load K,V tile once, compute for all Q heads in group.
 * Online softmax with causal mask.
 *
 * Grid: (seq_len_tiles, num_q_heads, batch_size)
 * Block: (BLOCK_SIZE)
 */
__global__ void glm5_mqa_attention_kernel(
    float* __restrict__ output,     // [batch, num_q_heads, seq_len, head_dim]
    const float* __restrict__ query, // [batch, num_q_heads, seq_len, head_dim]
    const float* __restrict__ key,   // [batch, num_kv_heads, seq_len, head_dim]
    const float* __restrict__ value, // [batch, num_kv_heads, seq_len, head_dim]
    const int batch_size,
    const int seq_len,
    const int num_q_heads,
    const int num_kv_heads,
    const int head_dim,
    const float scale,
    const int causal
) {
    extern __shared__ float smem[];
    
    int q_pos = blockIdx.x;
    int q_head = blockIdx.y;
    int batch_idx = blockIdx.z;
    int tid = threadIdx.x;
    
    if (q_pos >= seq_len || q_head >= num_q_heads) return;
    
    // Map Q head to KV head (16:1 ratio)
    int kv_head = q_head / (num_q_heads / num_kv_heads);
    
    // Load query for this position
    int q_offset = ((batch_idx * num_q_heads + q_head) * seq_len + q_pos) * head_dim;
    float* q_tile = smem;
    for (int d = tid; d < head_dim; d += BLOCK_SIZE) {
        q_tile[d] = query[q_offset + d];
    }
    __syncthreads();
    
    // Initialize accumulator and softmax state
    float* acc = smem + head_dim;
    float* max_val = smem + head_dim + head_dim;
    float* sum_exp = smem + head_dim + head_dim + 1;
    
    for (int d = tid; d < head_dim; d += BLOCK_SIZE) {
        acc[d] = 0.0f;
    }
    if (tid == 0) {
        max_val[0] = -FLT_MAX;
        sum_exp[0] = 0.0f;
    }
    __syncthreads();
    
    // Online softmax attention over sequence
    int kv_offset_base = (batch_idx * num_kv_heads + kv_head) * seq_len * head_dim;
    
    for (int k_pos = 0; k_pos < seq_len; k_pos++) {
        // Causal mask: skip future positions
        if (causal && k_pos > q_pos) continue;
        
        // Compute attention score: Q @ K^T / sqrt(d)
        float score = 0.0f;
        for (int d = tid; d < head_dim; d += BLOCK_SIZE) {
            int k_idx = kv_offset_base + k_pos * head_dim + d;
            score += q_tile[d] * key[k_idx];
        }
        
        // Warp reduce score
        for (int offset = WARP_SIZE / 2; offset > 0; offset /= 2) {
            score += __shfl_down_sync(0xffffffff, score, offset);
        }
        
        if (tid == 0) {
            score = score * scale;
            // Online softmax: update max and accumulate
            float old_max = max_val[0];
            max_val[0] = fmaxf(old_max, score);
            float exp_diff = expf(score - max_val[0]);
            sum_exp[0] = sum_exp[0] * expf(old_max - max_val[0]) + exp_diff;
        }
        __syncthreads();
        
        // Accumulate weighted value
        float weight = expf(score - max_val[0]) / (sum_exp[0] + 1e-8f);
        int v_offset = kv_offset_base + k_pos * head_dim;
        for (int d = tid; d < head_dim; d += BLOCK_SIZE) {
            acc[d] += weight * value[v_offset + d];
        }
        __syncthreads();
    }
    
    // Write output
    int out_offset = ((batch_idx * num_q_heads + q_head) * seq_len + q_pos) * head_dim;
    for (int d = tid; d < head_dim; d += BLOCK_SIZE) {
        output[out_offset + d] = acc[d];
    }
}

// ============================================================================
// GLM5 SwiGLU Kernel (Fused FFN Activation)
// ============================================================================

/**
 * SwiGLU: gate * silu(up) where silu(x) = x / (1 + exp(-x))
 * Element-wise operation, can be vectorized.
 *
 * Grid: ((batch*seq_len*hidden_dim + BLOCK_SIZE - 1) / BLOCK_SIZE)
 * Block: (BLOCK_SIZE)
 */
__global__ void glm5_swiglu_kernel(
    float* __restrict__ output,
    const float* __restrict__ gate,
    const float* __restrict__ up,
    const int total_elements
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < total_elements) {
        float g = __ldg(&gate[idx]);
        float u = __ldg(&up[idx]);
        // silu(u) = u / (1 + exp(-u))
        float silu_u = u / (1.0f + expf(-u));
        output[idx] = g * silu_u;
    }
}

// ============================================================================
// GLM5 RMSNorm Kernel
// ============================================================================

/**
 * RMS Normalization: output = input / rms * weight
 * where rms = sqrt(mean(input²) + eps)
 *
 * Uses FP32 accumulation for numerical stability.
 * Grid: (batch_size * seq_len)
 * Block: (BLOCK_SIZE)
 */
__global__ void glm5_rmsnorm_kernel(
    float* __restrict__ output,
    const float* __restrict__ input,
    const float* __restrict__ weight,
    const int hidden_dim,
    const float eps
) {
    extern __shared__ float sdata[];
    
    int row = blockIdx.x;
    int tid = threadIdx.x;
    
    // Accumulate sum of squares
    float sum_sq = 0.0f;
    int offset = row * hidden_dim;
    for (int d = tid; d < hidden_dim; d += BLOCK_SIZE) {
        float val = input[offset + d];
        sum_sq += val * val;
    }
    
    sdata[tid] = sum_sq;
    __syncthreads();
    
    // Block reduction
    for (int s = BLOCK_SIZE / 2; s > 0; s >>= 1) {
        if (tid < s) {
            sdata[tid] += sdata[tid + s];
        }
        __syncthreads();
    }
    
    // Compute RMS
    float rms = rsqrtf(sdata[0] / hidden_dim + eps);
    
    // Normalize and scale
    for (int d = tid; d < hidden_dim; d += BLOCK_SIZE) {
        output[offset + d] = input[offset + d] * rms * weight[d];
    }
}

// ============================================================================
// Extern C Wrappers
// ============================================================================

extern "C" int glm5_rope_forward(
    float* query, float* key,
    int batch_size, int seq_len, int num_q_heads, int num_kv_heads, int head_dim,
    int rope_dim, float theta_base
) {
    if (!query || !key) return -1;
    if (batch_size <= 0 || seq_len <= 0 || head_dim <= 0) return -1;
    
    dim3 grid(seq_len, num_q_heads, batch_size);
    dim3 block(BLOCK_SIZE);
    
    glm5_rope_kernel<<<grid, block>>>(
        query, key, batch_size, seq_len, num_q_heads, num_kv_heads,
        head_dim, rope_dim, theta_base
    );
    
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

extern "C" int glm5_mqa_forward(
    float* output, const float* query, const float* key, const float* value,
    int batch_size, int seq_len, int num_q_heads, int num_kv_heads, int head_dim,
    float scale, int causal
) {
    if (!output || !query || !key || !value) return -1;
    if (batch_size <= 0 || seq_len <= 0 || head_dim <= 0) return -1;
    
    dim3 grid(seq_len, num_q_heads, batch_size);
    dim3 block(BLOCK_SIZE);
    
    // Shared memory: Q tile + accumulator + softmax state
    size_t smem_size = (head_dim + head_dim + 2) * sizeof(float);
    
    glm5_mqa_attention_kernel<<<grid, block, smem_size>>>(
        output, query, key, value, batch_size, seq_len, num_q_heads, num_kv_heads,
        head_dim, scale, causal
    );
    
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

extern "C" int glm5_swiglu_forward(
    float* output, const float* gate, const float* up,
    int batch_size, int seq_len, int hidden_dim
) {
    if (!output || !gate || !up) return -1;
    if (batch_size <= 0 || seq_len <= 0 || hidden_dim <= 0) return -1;
    
    int total_elements = batch_size * seq_len * hidden_dim;
    int threads = BLOCK_SIZE;
    int blocks = (total_elements + threads - 1) / threads;
    
    glm5_swiglu_kernel<<<blocks, threads>>>(output, gate, up, total_elements);
    
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

extern "C" int glm5_rmsnorm_forward(
    float* output, const float* input, const float* weight,
    int batch_size, int seq_len, int hidden_dim, float eps
) {
    if (!output || !input || !weight) return -1;
    if (batch_size <= 0 || seq_len <= 0 || hidden_dim <= 0) return -1;
    
    int num_rows = batch_size * seq_len;
    size_t smem_size = BLOCK_SIZE * sizeof(float);
    
    glm5_rmsnorm_kernel<<<num_rows, BLOCK_SIZE, smem_size>>>(
        output, input, weight, hidden_dim, eps
    );
    
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}


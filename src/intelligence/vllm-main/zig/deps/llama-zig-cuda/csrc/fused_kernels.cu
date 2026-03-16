/**
 * Fused Kernels - Phase 2 Optimization
 * 
 * Combine multiple operations into single kernels to:
 * - Reduce kernel launch overhead
 * - Minimize memory bandwidth
 * - Keep data in registers/shared memory
 */

#include "cuda_kernels.h"
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <cmath>

// ============================================================================
// Constants
// ============================================================================

#define BLOCK_SIZE 256
#define WARP_SIZE 32

// ============================================================================
// Fused RMS Norm + Linear Projection
// ============================================================================

/**
 * Fused: RMS Norm → Linear
 * Avoids intermediate tensor storage
 * 
 * out = (x * rsqrt(mean(x²) + eps) * weight) @ proj_weight
 */
__global__ void fused_rmsnorm_linear_kernel(
    float* __restrict__ output,       // [batch, out_dim]
    const float* __restrict__ input,  // [batch, hidden_dim]
    const float* __restrict__ norm_weight,  // [hidden_dim]
    const float* __restrict__ proj_weight,  // [hidden_dim, out_dim]
    int batch_size,
    int hidden_dim,
    int out_dim,
    float eps
) {
    extern __shared__ float smem[];
    float* shared_input = smem;  // Normalized input
    
    int batch_idx = blockIdx.x;
    int tid = threadIdx.x;
    
    const float* x = input + batch_idx * hidden_dim;
    float* out = output + batch_idx * out_dim;
    
    // Step 1: Compute RMS
    float sum_sq = 0.0f;
    for (int i = tid; i < hidden_dim; i += BLOCK_SIZE) {
        float val = x[i];
        sum_sq += val * val;
    }
    
    // Warp reduction
    for (int offset = WARP_SIZE / 2; offset > 0; offset >>= 1) {
        sum_sq += __shfl_xor_sync(0xffffffff, sum_sq, offset);
    }
    
    // Block reduction
    __shared__ float block_sum[32];
    if (tid % WARP_SIZE == 0) {
        block_sum[tid / WARP_SIZE] = sum_sq;
    }
    __syncthreads();
    
    if (tid < WARP_SIZE) {
        sum_sq = (tid < (BLOCK_SIZE / WARP_SIZE)) ? block_sum[tid] : 0.0f;
        for (int offset = WARP_SIZE / 2; offset > 0; offset >>= 1) {
            sum_sq += __shfl_xor_sync(0xffffffff, sum_sq, offset);
        }
    }
    __syncthreads();
    
    float rms = rsqrtf(sum_sq / hidden_dim + eps);
    
    // Step 2: Normalize and store in shared memory
    for (int i = tid; i < hidden_dim; i += BLOCK_SIZE) {
        shared_input[i] = x[i] * rms * norm_weight[i];
    }
    __syncthreads();
    
    // Step 3: Linear projection
    for (int o = tid; o < out_dim; o += BLOCK_SIZE) {
        float acc = 0.0f;
        for (int h = 0; h < hidden_dim; h++) {
            acc += shared_input[h] * proj_weight[h * out_dim + o];
        }
        out[o] = acc;
    }
}

extern "C" int fused_rmsnorm_linear(
    float* output, const float* input,
    const float* norm_weight, const float* proj_weight,
    int batch_size, int hidden_dim, int out_dim, float eps
) {
    size_t smem_size = hidden_dim * sizeof(float);
    
    fused_rmsnorm_linear_kernel<<<batch_size, BLOCK_SIZE, smem_size>>>(
        output, input, norm_weight, proj_weight,
        batch_size, hidden_dim, out_dim, eps
    );
    
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

// ============================================================================
// Fused QKV Projection
// ============================================================================

/**
 * Fused: Linear → Split Q, K, V
 * Single kernel for QKV projection from hidden states
 * 
 * q, k, v = x @ Wq, x @ Wk, x @ Wv
 */
__global__ void fused_qkv_projection_kernel(
    float* __restrict__ q,          // [batch, seq, num_heads, head_dim]
    float* __restrict__ k,          // [batch, seq, num_kv_heads, head_dim]
    float* __restrict__ v,          // [batch, seq, num_kv_heads, head_dim]
    const float* __restrict__ x,    // [batch, seq, hidden_dim]
    const float* __restrict__ wq,   // [hidden_dim, num_heads * head_dim]
    const float* __restrict__ wk,   // [hidden_dim, num_kv_heads * head_dim]
    const float* __restrict__ wv,   // [hidden_dim, num_kv_heads * head_dim]
    int batch_size,
    int seq_len,
    int hidden_dim,
    int num_heads,
    int num_kv_heads,
    int head_dim
) {
    int batch_idx = blockIdx.z;
    int seq_idx = blockIdx.y;
    int head_idx = blockIdx.x;
    int tid = threadIdx.x;
    
    int q_heads_per_kv = num_heads / num_kv_heads;
    int kv_head_idx = head_idx / q_heads_per_kv;
    
    const float* x_pos = x + (batch_idx * seq_len + seq_idx) * hidden_dim;
    
    // Compute Q projection for this head
    float* q_out = q + ((batch_idx * seq_len + seq_idx) * num_heads + head_idx) * head_dim;
    for (int d = tid; d < head_dim; d += BLOCK_SIZE) {
        float acc = 0.0f;
        for (int h = 0; h < hidden_dim; h++) {
            acc += x_pos[h] * wq[h * (num_heads * head_dim) + head_idx * head_dim + d];
        }
        q_out[d] = acc;
    }
    
    // Only first Q head in group computes K and V
    if (head_idx % q_heads_per_kv == 0) {
        float* k_out = k + ((batch_idx * seq_len + seq_idx) * num_kv_heads + kv_head_idx) * head_dim;
        float* v_out = v + ((batch_idx * seq_len + seq_idx) * num_kv_heads + kv_head_idx) * head_dim;
        
        for (int d = tid; d < head_dim; d += BLOCK_SIZE) {
            float k_acc = 0.0f;
            float v_acc = 0.0f;
            for (int h = 0; h < hidden_dim; h++) {
                k_acc += x_pos[h] * wk[h * (num_kv_heads * head_dim) + kv_head_idx * head_dim + d];
                v_acc += x_pos[h] * wv[h * (num_kv_heads * head_dim) + kv_head_idx * head_dim + d];
            }
            k_out[d] = k_acc;
            v_out[d] = v_acc;
        }
    }
}

extern "C" int fused_qkv_projection(
    float* q, float* k, float* v, const float* x,
    const float* wq, const float* wk, const float* wv,
    int batch_size, int seq_len, int hidden_dim,
    int num_heads, int num_kv_heads, int head_dim
) {
    dim3 grid(num_heads, seq_len, batch_size);
    
    fused_qkv_projection_kernel<<<grid, BLOCK_SIZE>>>(
        q, k, v, x, wq, wk, wv,
        batch_size, seq_len, hidden_dim, num_heads, num_kv_heads, head_dim
    );
    
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

// ============================================================================
// Fused RoPE + Attention Score
// ============================================================================

/**
 * Fused: RoPE → Q @ K^T
 * Apply rotary embeddings and compute attention scores in one kernel
 *
 * WARNING: This kernel materializes the full [batch, num_heads, seq_q, seq_k]
 * score matrix in global memory — O(N²) memory usage. Use only for short
 * sequences (seq_len ≤ 512). For longer sequences, use Flash Attention
 * (flash_attention.cu) which computes attention in O(N) memory.
 */
__global__ void fused_rope_attention_kernel(
    float* __restrict__ scores,      // [batch, num_heads, seq_q, seq_k]
    const float* __restrict__ q,     // [batch, seq_q, num_heads, head_dim]
    const float* __restrict__ k,     // [batch, seq_k, num_kv_heads, head_dim]
    const float* __restrict__ cos,   // [max_seq, head_dim/2]
    const float* __restrict__ sin,   // [max_seq, head_dim/2]
    int batch_size,
    int seq_q,
    int seq_k,
    int num_heads,
    int num_kv_heads,
    int head_dim,
    float scale
) {
    extern __shared__ float smem[];
    float* q_rope = smem;
    
    int batch_idx = blockIdx.z;
    int head_idx = blockIdx.y;
    int q_idx = blockIdx.x;
    int tid = threadIdx.x;
    
    int kv_head_idx = head_idx * num_kv_heads / num_heads;
    
    // Load and apply RoPE to Q
    const float* q_in = q + ((batch_idx * seq_q + q_idx) * num_heads + head_idx) * head_dim;
    
    for (int i = tid; i < head_dim / 2; i += BLOCK_SIZE) {
        float cos_val = cos[q_idx * (head_dim / 2) + i];
        float sin_val = sin[q_idx * (head_dim / 2) + i];
        
        float q0 = q_in[i];
        float q1 = q_in[i + head_dim / 2];
        
        q_rope[i] = q0 * cos_val - q1 * sin_val;
        q_rope[i + head_dim / 2] = q0 * sin_val + q1 * cos_val;
    }
    __syncthreads();
    
    // Compute attention scores against all K positions
    for (int k_idx = tid; k_idx < seq_k; k_idx += BLOCK_SIZE) {
        const float* k_in = k + ((batch_idx * seq_k + k_idx) * num_kv_heads + kv_head_idx) * head_dim;
        
        // Apply RoPE to K (on the fly)
        float score = 0.0f;
        for (int i = 0; i < head_dim / 2; i++) {
            float cos_val = cos[k_idx * (head_dim / 2) + i];
            float sin_val = sin[k_idx * (head_dim / 2) + i];
            
            float k0 = k_in[i];
            float k1 = k_in[i + head_dim / 2];
            
            float k_rope_0 = k0 * cos_val - k1 * sin_val;
            float k_rope_1 = k0 * sin_val + k1 * cos_val;
            
            score += q_rope[i] * k_rope_0;
            score += q_rope[i + head_dim / 2] * k_rope_1;
        }
        
        scores[((batch_idx * num_heads + head_idx) * seq_q + q_idx) * seq_k + k_idx] = score * scale;
    }
}

extern "C" int fused_rope_attention(
    float* scores, const float* q, const float* k,
    const float* cos, const float* sin,
    int batch_size, int seq_q, int seq_k,
    int num_heads, int num_kv_heads, int head_dim, float scale
) {
    dim3 grid(seq_q, num_heads, batch_size);
    size_t smem_size = 2 * head_dim * sizeof(float);
    
    fused_rope_attention_kernel<<<grid, BLOCK_SIZE, smem_size>>>(
        scores, q, k, cos, sin,
        batch_size, seq_q, seq_k, num_heads, num_kv_heads, head_dim, scale
    );
    
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

// ============================================================================
// Fused SiLU + Elementwise Multiply (SwiGLU Gate)
// ============================================================================

/**
 * Fused: SiLU(gate) * up
 * Common pattern in Llama FFN
 */
__global__ void fused_swiglu_kernel(
    float* __restrict__ output,
    const float* __restrict__ gate,
    const float* __restrict__ up,
    int n
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        float g = gate[idx];
        float silu_g = g / (1.0f + expf(-g));
        output[idx] = silu_g * up[idx];
    }
}

extern "C" int fused_swiglu(
    float* output, const float* gate, const float* up, int n
) {
    int blocks = (n + BLOCK_SIZE - 1) / BLOCK_SIZE;
    fused_swiglu_kernel<<<blocks, BLOCK_SIZE>>>(output, gate, up, n);
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

// ============================================================================
// Fused Add + RMS Norm (Residual Connection)
// ============================================================================

/**
 * Fused: x = x + residual; y = RMSNorm(x)
 * Common pattern after attention/FFN
 */
__global__ void fused_add_rmsnorm_kernel(
    float* __restrict__ output,
    float* __restrict__ x,  // In-place update
    const float* __restrict__ residual,
    const float* __restrict__ weight,
    int batch_size,
    int hidden_dim,
    float eps
) {
    extern __shared__ float smem[];
    
    int batch_idx = blockIdx.x;
    int tid = threadIdx.x;
    
    float* x_row = x + batch_idx * hidden_dim;
    const float* res_row = residual + batch_idx * hidden_dim;
    float* out_row = output + batch_idx * hidden_dim;
    
    // Step 1: Add residual and compute sum of squares
    float sum_sq = 0.0f;
    for (int i = tid; i < hidden_dim; i += BLOCK_SIZE) {
        float val = x_row[i] + res_row[i];
        x_row[i] = val;  // In-place update
        sum_sq += val * val;
    }
    
    // Reduction for RMS
    for (int offset = WARP_SIZE / 2; offset > 0; offset >>= 1) {
        sum_sq += __shfl_xor_sync(0xffffffff, sum_sq, offset);
    }
    
    __shared__ float block_sum[32];
    if (tid % WARP_SIZE == 0) {
        block_sum[tid / WARP_SIZE] = sum_sq;
    }
    __syncthreads();
    
    if (tid == 0) {
        float total = 0.0f;
        for (int i = 0; i < BLOCK_SIZE / WARP_SIZE; i++) {
            total += block_sum[i];
        }
        smem[0] = rsqrtf(total / hidden_dim + eps);
    }
    __syncthreads();
    
    float rms = smem[0];
    
    // Step 2: Normalize
    for (int i = tid; i < hidden_dim; i += BLOCK_SIZE) {
        out_row[i] = x_row[i] * rms * weight[i];
    }
}

extern "C" int fused_add_rmsnorm(
    float* output, float* x, const float* residual,
    const float* weight, int batch_size, int hidden_dim, float eps
) {
    size_t smem_size = sizeof(float);
    
    fused_add_rmsnorm_kernel<<<batch_size, BLOCK_SIZE, smem_size>>>(
        output, x, residual, weight, batch_size, hidden_dim, eps
    );
    
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

// ============================================================================
// Fused Softmax + Dropout (Training)
// ============================================================================

__global__ void fused_softmax_dropout_kernel(
    float* __restrict__ output,
    const float* __restrict__ input,
    float dropout_prob,
    unsigned int seed,
    int batch_size,
    int seq_len
) {
    extern __shared__ float smem[];
    
    int batch_idx = blockIdx.x;
    int tid = threadIdx.x;
    
    const float* row = input + batch_idx * seq_len;
    float* out_row = output + batch_idx * seq_len;
    
    // Find max
    float max_val = -INFINITY;
    for (int i = tid; i < seq_len; i += BLOCK_SIZE) {
        max_val = fmaxf(max_val, row[i]);
    }
    
    for (int offset = WARP_SIZE / 2; offset > 0; offset >>= 1) {
        max_val = fmaxf(max_val, __shfl_xor_sync(0xffffffff, max_val, offset));
    }
    
    __shared__ float shared_max[32];
    if (tid % WARP_SIZE == 0) shared_max[tid / WARP_SIZE] = max_val;
    __syncthreads();
    
    if (tid == 0) {
        float m = shared_max[0];
        for (int i = 1; i < BLOCK_SIZE / WARP_SIZE; i++) {
            m = fmaxf(m, shared_max[i]);
        }
        smem[0] = m;
    }
    __syncthreads();
    max_val = smem[0];
    
    // Compute exp and sum
    float sum = 0.0f;
    for (int i = tid; i < seq_len; i += BLOCK_SIZE) {
        sum += expf(row[i] - max_val);
    }
    
    for (int offset = WARP_SIZE / 2; offset > 0; offset >>= 1) {
        sum += __shfl_xor_sync(0xffffffff, sum, offset);
    }
    
    __shared__ float shared_sum[32];
    if (tid % WARP_SIZE == 0) shared_sum[tid / WARP_SIZE] = sum;
    __syncthreads();
    
    if (tid == 0) {
        float s = 0.0f;
        for (int i = 0; i < BLOCK_SIZE / WARP_SIZE; i++) {
            s += shared_sum[i];
        }
        smem[1] = s;
    }
    __syncthreads();
    sum = smem[1];
    
    // Softmax + dropout
    float inv_keep = 1.0f / (1.0f - dropout_prob);
    for (int i = tid; i < seq_len; i += BLOCK_SIZE) {
        float softmax_val = expf(row[i] - max_val) / sum;
        
        // Philox-style hash for deterministic, high-quality per-element randomness
        // Combines seed, batch index, and position for unique state per element
        unsigned int rng_state = seed ^ (unsigned int)(batch_idx * 2654435761u) ^ (unsigned int)(i * 2246822519u);
        rng_state ^= rng_state >> 16;
        rng_state *= 0x45d9f3bu;
        rng_state ^= rng_state >> 16;
        rng_state *= 0x45d9f3bu;
        rng_state ^= rng_state >> 16;
        
        // Convert to [0, 1) float and compare against dropout probability
        float rand_val = (float)(rng_state & 0x00FFFFFFu) / 16777216.0f;  // 2^24
        float drop = (rand_val < dropout_prob) ? 0.0f : inv_keep;
        
        out_row[i] = softmax_val * drop;
    }
}

extern "C" int fused_softmax_dropout(
    float* output, const float* input,
    float dropout_prob, unsigned int seed,
    int batch_size, int seq_len
) {
    size_t smem_size = 2 * sizeof(float);
    
    fused_softmax_dropout_kernel<<<batch_size, BLOCK_SIZE, smem_size>>>(
        output, input, dropout_prob, seed, batch_size, seq_len
    );
    
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

// ============================================================================
// Fused Embedding + Layer Norm (Input Processing)
// ============================================================================

__global__ void fused_embedding_layernorm_kernel(
    float* __restrict__ output,
    const int* __restrict__ input_ids,
    const float* __restrict__ embedding_table,
    const float* __restrict__ ln_weight,
    const float* __restrict__ ln_bias,
    int batch_size,
    int seq_len,
    int hidden_dim,
    float eps
) {
    extern __shared__ float smem[];
    
    int batch_idx = blockIdx.y;
    int seq_idx = blockIdx.x;
    int tid = threadIdx.x;
    
    int token_id = input_ids[batch_idx * seq_len + seq_idx];
    const float* emb = embedding_table + token_id * hidden_dim;
    float* out = output + (batch_idx * seq_len + seq_idx) * hidden_dim;
    
    // Load embedding and compute mean
    float sum = 0.0f;
    for (int i = tid; i < hidden_dim; i += BLOCK_SIZE) {
        smem[i] = emb[i];
        sum += emb[i];
    }
    
    // Reduce for mean
    for (int offset = WARP_SIZE / 2; offset > 0; offset >>= 1) {
        sum += __shfl_xor_sync(0xffffffff, sum, offset);
    }
    
    __shared__ float shared_sum[32];
    if (tid % WARP_SIZE == 0) shared_sum[tid / WARP_SIZE] = sum;
    __syncthreads();
    
    float mean = 0.0f;
    if (tid == 0) {
        for (int i = 0; i < BLOCK_SIZE / WARP_SIZE; i++) {
            mean += shared_sum[i];
        }
        mean /= hidden_dim;
    }
    __syncthreads();
    
    // Compute variance
    float var_sum = 0.0f;
    for (int i = tid; i < hidden_dim; i += BLOCK_SIZE) {
        float diff = smem[i] - mean;
        var_sum += diff * diff;
    }
    
    for (int offset = WARP_SIZE / 2; offset > 0; offset >>= 1) {
        var_sum += __shfl_xor_sync(0xffffffff, var_sum, offset);
    }
    
    if (tid % WARP_SIZE == 0) shared_sum[tid / WARP_SIZE] = var_sum;
    __syncthreads();
    
    float var = 0.0f;
    if (tid == 0) {
        for (int i = 0; i < BLOCK_SIZE / WARP_SIZE; i++) {
            var += shared_sum[i];
        }
        var = rsqrtf(var / hidden_dim + eps);
    }
    __syncthreads();
    
    // Normalize and output
    for (int i = tid; i < hidden_dim; i += BLOCK_SIZE) {
        out[i] = (smem[i] - mean) * var * ln_weight[i] + ln_bias[i];
    }
}

extern "C" int fused_embedding_layernorm(
    float* output, const int* input_ids,
    const float* embedding_table, const float* ln_weight, const float* ln_bias,
    int batch_size, int seq_len, int hidden_dim, float eps
) {
    dim3 grid(seq_len, batch_size);
    size_t smem_size = hidden_dim * sizeof(float);
    
    fused_embedding_layernorm_kernel<<<grid, BLOCK_SIZE, smem_size>>>(
        output, input_ids, embedding_table, ln_weight, ln_bias,
        batch_size, seq_len, hidden_dim, eps
    );
    
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

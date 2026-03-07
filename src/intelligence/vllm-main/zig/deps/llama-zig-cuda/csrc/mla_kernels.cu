/**
 * Multi-Latent Attention (MLA) CUDA Kernels
 *
 * GPU-accelerated kernels for DeepSeek-style MLA:
 * 1. mla_compress_kv_kernel: Fused linear projection + partial RoPE for KV compression
 * 2. mla_attention_kernel: Flash Attention operating on compressed latent KV cache
 *
 * Memory savings: 4-8× vs standard GQA KV cache
 */

#include "cuda_kernels.h"
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <cstdint>
#include <cmath>

#define MLA_BLOCK_SIZE 256
#define MLA_WARP_SIZE 32

// ============================================================================
// 1. Fused KV Compression + RoPE
// ============================================================================

/**
 * Compress hidden states into latent KV representation + RoPE-K.
 *
 * Computes:
 *   latent[latent_dim]           = W_kv_down @ x[hidden_dim]
 *   k_rope[num_kv_heads*rope_dim] = RoPE(W_k_rope @ x[hidden_dim], position)
 *
 * Grid:  (num_seq)
 * Block: (MLA_BLOCK_SIZE)
 */
__global__ void mla_compress_kv_kernel(
    float* __restrict__ latent_out,      // [num_seq, latent_dim]
    float* __restrict__ k_rope_out,      // [num_seq, num_kv_heads * rope_dim]
    const float* __restrict__ x,         // [num_seq, hidden_dim]
    const float* __restrict__ w_kv_down, // [latent_dim, hidden_dim]
    const float* __restrict__ w_k_rope,  // [num_kv_heads * rope_dim, hidden_dim]
    int hidden_dim,
    int latent_dim,
    int num_kv_heads,
    int rope_dim,
    int position,
    float rope_theta
) {
    int seq_idx = blockIdx.x;
    int tid = threadIdx.x;

    const float* x_row = x + (size_t)seq_idx * hidden_dim;

    // Phase 1: Compute latent = W_kv_down @ x
    for (int i = tid; i < latent_dim; i += MLA_BLOCK_SIZE) {
        float sum = 0.0f;
        const float* w_row = w_kv_down + (size_t)i * hidden_dim;
        for (int j = 0; j < hidden_dim; j++) {
            sum += w_row[j] * x_row[j];
        }
        latent_out[(size_t)seq_idx * latent_dim + i] = sum;
    }

    // Phase 2: Compute k_rope = W_k_rope @ x
    int rope_k_dim = num_kv_heads * rope_dim;
    for (int i = tid; i < rope_k_dim; i += MLA_BLOCK_SIZE) {
        float sum = 0.0f;
        const float* w_row = w_k_rope + (size_t)i * hidden_dim;
        for (int j = 0; j < hidden_dim; j++) {
            sum += w_row[j] * x_row[j];
        }
        k_rope_out[(size_t)seq_idx * rope_k_dim + i] = sum;
    }
    __syncthreads();

    // Phase 3: Apply RoPE to k_rope in-place
    int half_rope = rope_dim / 2;
    for (int h = 0; h < num_kv_heads; h++) {
        int base = (int)((size_t)seq_idx * rope_k_dim + h * rope_dim);
        for (int d = tid; d < half_rope; d += MLA_BLOCK_SIZE) {
            float freq = 1.0f / powf(rope_theta, (float)(2 * d) / (float)rope_dim);
            float angle = (float)position * freq;
            float cos_t = cosf(angle);
            float sin_t = sinf(angle);

            float v0 = k_rope_out[base + d];
            float v1 = k_rope_out[base + half_rope + d];
            k_rope_out[base + d]            = v0 * cos_t - v1 * sin_t;
            k_rope_out[base + half_rope + d] = v0 * sin_t + v1 * cos_t;
        }
    }
}

extern "C" int mla_compress_kv(
    float* latent_out, float* k_rope_out,
    const float* x, const float* w_kv_down, const float* w_k_rope,
    int num_seq, int hidden_dim, int latent_dim,
    int num_kv_heads, int rope_dim, int position, float rope_theta
) {
    mla_compress_kv_kernel<<<num_seq, MLA_BLOCK_SIZE>>>(
        latent_out, k_rope_out, x, w_kv_down, w_k_rope,
        hidden_dim, latent_dim, num_kv_heads, rope_dim, position, rope_theta
    );
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

// ============================================================================
// 2. MLA Attention Kernel (Flash Attention on compressed KV)
// ============================================================================

/**
 * Attention with on-the-fly KV decompression from latent cache.
 *
 * For each query head h (with GQA mapping to kv_head):
 *   For each cached position pos:
 *     K_nope = W_k_up @ latent[pos]          — decompress K
 *     K_rope = k_rope_cache[pos]             — pre-computed
 *     score  = (Q_nope · K_nope + Q_rope · K_rope) * scale
 *   Online softmax over scores
 *   For each cached position pos:
 *     V = W_v_up @ latent[pos]               — decompress V
 *     output += softmax_weight * V
 *
 * Two-pass to avoid storing all decompressed V in memory.
 *
 * Grid:  (num_heads, num_seq)
 * Block: (MLA_BLOCK_SIZE)
 */
__global__ void mla_attention_kernel(
    float* __restrict__ output,          // [num_seq, num_heads, head_dim]
    const float* __restrict__ q_nope,    // [num_seq, num_heads, nope_dim]
    const float* __restrict__ q_rope,    // [num_seq, num_heads, rope_dim]
    const float* __restrict__ latent_cache, // [seq_len, latent_dim]
    const float* __restrict__ k_rope_cache, // [seq_len, num_kv_heads * rope_dim]
    const float* __restrict__ w_k_up,    // [num_kv_heads * nope_dim, latent_dim]
    const float* __restrict__ w_v_up,    // [num_kv_heads * head_dim, latent_dim]
    int seq_len,
    int num_heads,
    int num_kv_heads,
    int head_dim,
    int nope_dim,
    int rope_dim,
    int latent_dim,
    float scale
) {
    int head_idx = blockIdx.x;
    int seq_idx  = blockIdx.y;
    int tid      = threadIdx.x;

    if (seq_len <= 0) return;

    int kv_per_q = num_heads / num_kv_heads;
    int kv_head = head_idx / kv_per_q;

    extern __shared__ float smem[];
    float* scores = smem;  // [seq_len]

    // Pass 1: Compute attention scores
    // Q_nope for this head: [nope_dim]
    const float* q_nope_h = q_nope + ((size_t)seq_idx * num_heads + head_idx) * nope_dim;
    const float* q_rope_h = q_rope + ((size_t)seq_idx * num_heads + head_idx) * rope_dim;

    float max_score = -INFINITY;

    for (int pos = tid; pos < seq_len; pos += MLA_BLOCK_SIZE) {
        const float* latent = latent_cache + (size_t)pos * latent_dim;

        // Decompress K_nope and compute dot with Q_nope
        float nope_dot = 0.0f;
        for (int d = 0; d < nope_dim; d++) {
            int k_idx = kv_head * nope_dim + d;
            float k_val = 0.0f;
            for (int l = 0; l < latent_dim; l++) {
                k_val += w_k_up[(size_t)k_idx * latent_dim + l] * latent[l];
            }
            nope_dot += q_nope_h[d] * k_val;
        }

        // K_rope dot product (pre-computed, no decompression)
        const float* k_rope_pos = k_rope_cache + (size_t)pos * num_kv_heads * rope_dim
                                + (size_t)kv_head * rope_dim;
        float rope_dot = 0.0f;
        for (int d = 0; d < rope_dim; d++) {
            rope_dot += q_rope_h[d] * k_rope_pos[d];
        }

        float score = (nope_dot + rope_dot) * scale;
        scores[pos] = score;
        max_score = fmaxf(max_score, score);
    }
    __syncthreads();

    // Reduce max across threads
    __shared__ float shared_reduce[32];
    for (int offset = MLA_WARP_SIZE / 2; offset > 0; offset >>= 1)
        max_score = fmaxf(max_score, __shfl_xor_sync(0xffffffff, max_score, offset));
    if (tid % MLA_WARP_SIZE == 0) shared_reduce[tid / MLA_WARP_SIZE] = max_score;
    __syncthreads();
    if (tid == 0) {
        float m = -INFINITY;
        for (int i = 0; i < MLA_BLOCK_SIZE / MLA_WARP_SIZE; i++)
            m = fmaxf(m, shared_reduce[i]);
        shared_reduce[0] = m;
    }
    __syncthreads();
    max_score = shared_reduce[0];

    // Softmax: exp and sum
    float local_sum = 0.0f;
    for (int pos = tid; pos < seq_len; pos += MLA_BLOCK_SIZE) {
        float s = expf(scores[pos] - max_score);
        scores[pos] = s;
        local_sum += s;
    }

    for (int offset = MLA_WARP_SIZE / 2; offset > 0; offset >>= 1)
        local_sum += __shfl_xor_sync(0xffffffff, local_sum, offset);
    if (tid % MLA_WARP_SIZE == 0) shared_reduce[tid / MLA_WARP_SIZE] = local_sum;
    __syncthreads();
    if (tid == 0) {
        float s = 0.0f;
        for (int i = 0; i < MLA_BLOCK_SIZE / MLA_WARP_SIZE; i++) s += shared_reduce[i];
        shared_reduce[0] = (s > 0.0f) ? (1.0f / s) : 0.0f;
    }
    __syncthreads();
    float inv_sum = shared_reduce[0];

    // Pass 2: Weighted sum of decompressed V
    float* out_ptr = output + ((size_t)seq_idx * num_heads + head_idx) * head_dim;

    for (int d = tid; d < head_dim; d += MLA_BLOCK_SIZE) {
        float acc = 0.0f;
        int v_idx = kv_head * head_dim + d;

        for (int pos = 0; pos < seq_len; pos++) {
            float weight = scores[pos] * inv_sum;
            if (weight == 0.0f) continue;

            const float* latent = latent_cache + (size_t)pos * latent_dim;
            float v_val = 0.0f;
            for (int l = 0; l < latent_dim; l++) {
                v_val += w_v_up[(size_t)v_idx * latent_dim + l] * latent[l];
            }
            acc += weight * v_val;
        }
        out_ptr[d] = acc;
    }
}

extern "C" int mla_attention_forward(
    float* output,
    const float* q_nope, const float* q_rope,
    const float* latent_cache, const float* k_rope_cache,
    const float* w_k_up, const float* w_v_up,
    int num_seq, int seq_len,
    int num_heads, int num_kv_heads, int head_dim,
    int nope_dim, int rope_dim, int latent_dim, float scale
) {
    dim3 grid(num_heads, num_seq);
    size_t smem_size = (size_t)seq_len * sizeof(float);

    mla_attention_kernel<<<grid, MLA_BLOCK_SIZE, smem_size>>>(
        output, q_nope, q_rope,
        latent_cache, k_rope_cache, w_k_up, w_v_up,
        seq_len, num_heads, num_kv_heads, head_dim,
        nope_dim, rope_dim, latent_dim, scale
    );

    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

// ============================================================================
// Core GPU Kernels — nvcc-compiled replacements for Zig PTX kernels.
// These provide the fundamental ops needed for transformer inference:
// sgemv, rms_norm, rope, embedding, swiglu, vector_add.
//
// Compile: nvcc -O3 -arch=sm_70 -ptx core_kernels.cu -o core_kernels.ptx
// ============================================================================

#include <cuda_fp16.h>
#include <cstdint>

// ============================================================================
// 1. sgemv: y[M] = alpha * A[M×K] @ x[K] + beta * y[M]
// ============================================================================
// Grid: (ceil(M/256), 1), Block: (256, 1) — one thread per row, serial inner loop.
// Matches the dispatch grid in cuda_backend.zig sgemvGpu.
extern "C" __global__ void sgemv(
    float* __restrict__ y,
    const float* __restrict__ A,
    const float* __restrict__ x,
    int M, int K,
    float alpha, float beta)
{
    int row = blockIdx.x * blockDim.x + threadIdx.x;
    if (row >= M) return;

    const float* A_row = A + (long long)row * K;
    float acc = 0.0f;
    for (int j = 0; j < K; j++)
        acc += A_row[j] * x[j];

    float val = alpha * acc;
    if (beta != 0.0f) val += beta * y[row];
    y[row] = val;
}

// ============================================================================
// 2. rms_norm: out[i] = (x[i] / rms(x)) * weight[i]
// ============================================================================
// Grid: (1, 1), Block: (256, 1)
extern "C" __global__ void rms_norm(
    float* __restrict__ out,
    const float* __restrict__ x,
    const float* __restrict__ weight,
    int dim, float eps)
{
    __shared__ float smem[256];
    int tid = threadIdx.x;

    // Compute sum of squares
    float sum_sq = 0.0f;
    for (int i = tid; i < dim; i += blockDim.x)
        sum_sq += x[i] * x[i];
    smem[tid] = sum_sq;
    __syncthreads();

    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) smem[tid] += smem[tid + s];
        __syncthreads();
    }

    float rms = rsqrtf(smem[0] / (float)dim + eps);
    __syncthreads();

    for (int i = tid; i < dim; i += blockDim.x)
        out[i] = x[i] * rms * weight[i];
}

// ============================================================================
// 3. rms_norm_batch: per-head RMS norm (for QK-norm)
// ============================================================================
// Grid: (n_heads, 1), Block: (256, 1)
extern "C" __global__ void rms_norm_batch(
    float* __restrict__ out,
    const float* __restrict__ x,
    const float* __restrict__ weight,
    int head_dim, float eps, int n_heads)
{
    int h = blockIdx.x;
    if (h >= n_heads) return;
    int tid = threadIdx.x;

    const float* x_h = x + h * head_dim;
    float* out_h = out + h * head_dim;

    __shared__ float smem[256];
    float sum_sq = 0.0f;
    for (int i = tid; i < head_dim; i += blockDim.x)
        sum_sq += x_h[i] * x_h[i];
    smem[tid] = sum_sq;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) smem[tid] += smem[tid + s];
        __syncthreads();
    }
    float rms = rsqrtf(smem[0] / (float)head_dim + eps);
    __syncthreads();
    for (int i = tid; i < head_dim; i += blockDim.x)
        out_h[i] = x_h[i] * rms * weight[i];
}

// ============================================================================
// 4. rope_q: Apply RoPE to query vectors (all heads)
// ============================================================================
// Grid: (ceil(total_pairs/256), 1), Block: (256, 1) — one thread per (head, pair) combo
extern "C" __global__ void rope_q(
    float* __restrict__ q,
    int pos, int head_dim, float freq_base, int n_heads)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    int half_dim = head_dim / 2;
    int total_pairs = n_heads * half_dim;
    if (idx >= total_pairs) return;

    int h = idx / half_dim;
    int i = idx % half_dim;
    float* q_head = q + h * head_dim;

    float freq = 1.0f / powf(freq_base, (float)(2 * i) / (float)head_dim);
    float angle = (float)pos * freq;
    float cos_a = cosf(angle);
    float sin_a = sinf(angle);
    float v0 = q_head[i];
    float v1 = q_head[i + half_dim];
    q_head[i]            = v0 * cos_a - v1 * sin_a;
    q_head[i + half_dim] = v0 * sin_a + v1 * cos_a;
}

// ============================================================================
// 5. rope_k: Apply RoPE to key vectors (KV heads)
// ============================================================================
// Grid: (ceil(total_pairs/256), 1), Block: (256, 1)
extern "C" __global__ void rope_k(
    float* __restrict__ k,
    int pos, int head_dim, float freq_base, int n_kv_heads)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    int half_dim = head_dim / 2;
    int total_pairs = n_kv_heads * half_dim;
    if (idx >= total_pairs) return;

    int h = idx / half_dim;
    int i = idx % half_dim;
    float* k_head = k + h * head_dim;

    float freq = 1.0f / powf(freq_base, (float)(2 * i) / (float)head_dim);
    float angle = (float)pos * freq;
    float cos_a = cosf(angle);
    float sin_a = sinf(angle);
    float v0 = k_head[i];
    float v1 = k_head[i + half_dim];
    k_head[i]            = v0 * cos_a - v1 * sin_a;
    k_head[i + half_dim] = v0 * sin_a + v1 * cos_a;
}

// ============================================================================
// 6. embedding_lookup: out[dim] = table[token * dim .. (token+1) * dim]
// ============================================================================
// Grid: (ceil(dim/256), 1), Block: (256, 1)
extern "C" __global__ void embedding_lookup(
    float* __restrict__ out,
    const float* __restrict__ table,
    int token, int dim)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= dim) return;
    out[i] = table[(long long)token * dim + i];
}

// ============================================================================
// 7. swiglu: out[i] = silu(gate[i]) * up[i]
// ============================================================================
// Grid: (ceil(dim/256), 1), Block: (256, 1)
extern "C" __global__ void swiglu(
    float* __restrict__ out,
    const float* __restrict__ gate,
    const float* __restrict__ up,
    int dim)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= dim) return;
    float g = gate[i];
    float silu_g = g / (1.0f + expf(-g));
    out[i] = silu_g * up[i];
}

// ============================================================================
// 8. vector_add: out[i] = a[i] + b[i]
// ============================================================================
// Grid: (ceil(dim/256), 1), Block: (256, 1)
extern "C" __global__ void vector_add(
    float* __restrict__ out,
    const float* __restrict__ a,
    const float* __restrict__ b,
    int dim)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= dim) return;
    out[i] = a[i] + b[i];
}

// ============================================================================
// 9. softmax: in-place softmax over dim elements
// ============================================================================
// Grid: (1, 1), Block: (256, 1)
extern "C" __global__ void softmax(
    float* __restrict__ x,
    int dim)
{
    __shared__ float smem[256];
    int tid = threadIdx.x;

    // Find max
    float max_val = -1e30f;
    for (int i = tid; i < dim; i += blockDim.x)
        max_val = fmaxf(max_val, x[i]);
    smem[tid] = max_val;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) smem[tid] = fmaxf(smem[tid], smem[tid + s]);
        __syncthreads();
    }
    max_val = smem[0];
    __syncthreads();

    // Exp and sum
    float sum = 0.0f;
    for (int i = tid; i < dim; i += blockDim.x) {
        x[i] = expf(x[i] - max_val);
        sum += x[i];
    }
    smem[tid] = sum;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) smem[tid] += smem[tid + s];
        __syncthreads();
    }
    float inv_sum = 1.0f / smem[0];
    __syncthreads();

    for (int i = tid; i < dim; i += blockDim.x)
        x[i] *= inv_sum;
}

// ============================================================================
// 10. dequantize_q4_0: Q4_0 blocks → F32 (for batched SGEMM path)
// ============================================================================
// Grid: (ceil(n_blocks/256), 1), Block: (256, 1)
// Each thread handles one Q4_0 block (32 elements)
extern "C" __global__ void dequantize_q4_0(
    float* __restrict__ out,
    const uint8_t* __restrict__ data,
    int M, int K)
{
    int blocks_per_row = K / 32;
    int total_blocks = M * blocks_per_row;
    int bid = blockIdx.x * blockDim.x + threadIdx.x;
    if (bid >= total_blocks) return;

    int row = bid / blocks_per_row;
    int col_block = bid % blocks_per_row;
    const uint8_t* block = data + (long long)row * blocks_per_row * 18 + col_block * 18;
    float scale = __half2float(*reinterpret_cast<const __half*>(block));
    float* dst = out + (long long)row * K + col_block * 32;

    for (int j = 0; j < 16; j++) {
        uint8_t byte = block[2 + j];
        dst[j]      = ((float)(int)(byte & 0xF) - 8.0f) * scale;
        dst[j + 16] = ((float)(int)(byte >> 4)  - 8.0f) * scale;
    }
}

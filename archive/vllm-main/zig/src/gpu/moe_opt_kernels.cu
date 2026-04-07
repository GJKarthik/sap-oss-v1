// MoE optimization kernels for Zig CUDA backend
// Compile: nvcc -ptx -arch=sm_75 -o moe_opt_kernels.ptx moe_opt_kernels.cu
//
// Two kernels that eliminate per-layer CPU sync in MoE forward pass:
// 1. softmax_topk_kernel: GPU-side router softmax + TopK (replaces CPU roundtrip)
// 2. dequant_topk_experts_q4_fp16: Batched dequant reading expert_ids from GPU memory

#include <cuda_fp16.h>

// GPU-side softmax + TopK on router HGEMM output
// Runs as single-thread kernel — n_experts is small (96-128), latency ~2μs
// Input: router_logits[n_experts] FP16 from HGEMM
// Output: expert_ids[topk] (int32), expert_weights[topk] (float32, normalized)
extern "C" __global__ void softmax_topk_kernel(
    int* __restrict__ expert_ids,
    float* __restrict__ expert_weights,
    const __half* __restrict__ router_logits,
    int n_experts, int topk)
{
    if (threadIdx.x != 0) return;

    float scores[256];  // max 256 experts
    float max_val = -1e30f;
    for (int e = 0; e < n_experts; e++) {
        scores[e] = __half2float(router_logits[e]);
        max_val = fmaxf(max_val, scores[e]);
    }

    float sum_exp = 0.0f;
    for (int e = 0; e < n_experts; e++) {
        scores[e] = expf(scores[e] - max_val);
        sum_exp += scores[e];
    }
    for (int e = 0; e < n_experts; e++) scores[e] /= sum_exp;

    // TopK by iterative argmax
    for (int k = 0; k < topk; k++) {
        int best_e = 0;
        float best_w = -1.0f;
        for (int e = 0; e < n_experts; e++) {
            if (scores[e] > best_w) {
                best_e = e;
                best_w = scores[e];
            }
        }
        expert_ids[k] = best_e;
        expert_weights[k] = best_w;
        scores[best_e] = -1.0f;  // mask out selected expert
    }

    // Renormalize TopK weights
    float wsum = 0.0f;
    for (int k = 0; k < topk; k++) wsum += expert_weights[k];
    if (wsum > 0.0f) for (int k = 0; k < topk; k++) expert_weights[k] /= wsum;
}

// Batched Q4_0 → FP16 dequant for TopK experts from stacked tensor
// Reads expert_ids[topk] from device memory — no host roundtrip needed
// Output: fp16_out[topk × rows × cols] stacked contiguously
extern "C" __global__ void dequant_topk_experts_q4_fp16(
    __half* __restrict__ out,
    const unsigned char* __restrict__ q4_base,
    const int* __restrict__ expert_ids,
    int topk, int rows, int cols)
{
    int n_blocks_per_row = cols >> 5;
    int bytes_per_row = n_blocks_per_row * 18;
    int total_work = topk * rows * n_blocks_per_row;
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= total_work) return;

    int ki = idx / (rows * n_blocks_per_row);
    int rem = idx % (rows * n_blocks_per_row);
    int row = rem / n_blocks_per_row;
    int col_block = rem % n_blocks_per_row;

    int e = expert_ids[ki];
    if (e < 0) return;

    long long expert_offset = (long long)e * rows * bytes_per_row;
    const unsigned char* bp = q4_base + expert_offset + (long long)row * bytes_per_row + col_block * 18;
    float scale = __half2float(*reinterpret_cast<const __half*>(bp));

    int out_base = ki * rows * cols + row * cols + col_block * 32;
    for (int j = 0; j < 16; j++) {
        unsigned char byte = bp[2 + j];
        out[out_base + j]      = __float2half(((float)(byte & 0xF) - 8.0f) * scale);
        out[out_base + j + 16] = __float2half(((float)(byte >> 4) - 8.0f) * scale);
    }
}

// Batched Q4_0 GEMV: Y[bi*M + row] = W_q4[M×K] @ X[bi*K + :]
// 2D grid: blockIdx.x = row groups (ceil(M/8)), blockIdx.y = batch index
// Each block handles 8 rows for 1 batch vector. L2 cache amortizes weight
// reads across concurrent blocks processing different batch vectors.
// Shared memory: padded x vector for bank-conflict-free access.
extern "C" __global__ void q4_0_gemv_batch(
    float* __restrict__ Y,
    const unsigned char* __restrict__ W,
    const float* __restrict__ X,
    int M, int K, int batch_size)
{
    extern __shared__ float x_smem[];
    int tid = threadIdx.x;
    int n_blocks_per_row = K >> 5;
    int bi = blockIdx.y;  // batch index

    // Load this batch vector into shared memory
    const float* x_bi = X + (long long)bi * K;
    for (int idx = tid; idx < K; idx += 256) {
        int padded = idx + (idx >> 5);
        x_smem[padded] = __ldg(&x_bi[idx]);
    }
    __syncthreads();

    int tx = tid & 31;
    int ty = tid >> 5;
    int row = blockIdx.x * 8 + ty;
    if (row >= M) return;

    const unsigned char* W_row = W + (long long)row * n_blocks_per_row * 18;

    float acc = 0.0f;
    for (int b = tx; b < n_blocks_per_row; b += 32) {
        const unsigned char* block_ptr = W_row + b * 18;
        float scale = __half2float(*reinterpret_cast<const __half*>(block_ptr));
        float neg8_scale = scale * (-8.0f);
        int x_base = b * 33;

        const unsigned short* data_u16 = reinterpret_cast<const unsigned short*>(block_ptr + 2);
        #pragma unroll
        for (int j = 0; j < 8; j++) {
            unsigned short val = __ldg(&data_u16[j]);
            unsigned char b0 = val & 0xFF;
            unsigned char b1 = val >> 8;
            float w0 = (float)(b0 & 0xF) * scale + neg8_scale;
            float w1 = (float)(b0 >> 4)  * scale + neg8_scale;
            float w2 = (float)(b1 & 0xF) * scale + neg8_scale;
            float w3 = (float)(b1 >> 4)  * scale + neg8_scale;
            acc += w0 * x_smem[x_base + j*4]
                 + w1 * x_smem[x_base + j*4 + 1]
                 + w2 * x_smem[x_base + j*4 + 2]
                 + w3 * x_smem[x_base + j*4 + 3];
        }
    }

    #pragma unroll
    for (int offset = 16; offset >= 1; offset >>= 1)
        acc += __shfl_xor_sync(0xFFFFFFFF, acc, offset);
    if (tx == 0) Y[(long long)bi * M + row] = acc;
}

// Gather-fused batched Q4_0 GEMV: same as q4_0_gemv_batch but reads input from
// scattered positions via index array. Eliminates separate gather_vectors launch.
// Y[bi*M + row] = W_q4[M×K] @ X[indices[bi]*K + :]
extern "C" __global__ void q4_0_gemv_batch_gather(
    float* __restrict__ Y,
    const unsigned char* __restrict__ W,
    const float* __restrict__ X,
    const int* __restrict__ indices,
    int M, int K, int batch_size)
{
    extern __shared__ float x_smem[];
    int tid = threadIdx.x;
    int n_blocks_per_row = K >> 5;
    int bi = blockIdx.y;  // batch index

    // Load this batch vector from SCATTERED position into shared memory
    const float* x_bi = X + (long long)indices[bi] * K;
    for (int idx = tid; idx < K; idx += 256) {
        int padded = idx + (idx >> 5);
        x_smem[padded] = __ldg(&x_bi[idx]);
    }
    __syncthreads();

    int tx = tid & 31;
    int ty = tid >> 5;
    int row = blockIdx.x * 8 + ty;
    if (row >= M) return;

    const unsigned char* W_row = W + (long long)row * n_blocks_per_row * 18;

    float acc = 0.0f;
    for (int b = tx; b < n_blocks_per_row; b += 32) {
        const unsigned char* block_ptr = W_row + b * 18;
        float scale = __half2float(*reinterpret_cast<const __half*>(block_ptr));
        float neg8_scale = scale * (-8.0f);
        int x_base = b * 33;

        const unsigned short* data_u16 = reinterpret_cast<const unsigned short*>(block_ptr + 2);
        #pragma unroll
        for (int j = 0; j < 8; j++) {
            unsigned short val = __ldg(&data_u16[j]);
            unsigned char b0 = val & 0xFF;
            unsigned char b1 = val >> 8;
            float w0 = (float)(b0 & 0xF) * scale + neg8_scale;
            float w1 = (float)(b0 >> 4)  * scale + neg8_scale;
            float w2 = (float)(b1 & 0xF) * scale + neg8_scale;
            float w3 = (float)(b1 >> 4)  * scale + neg8_scale;
            acc += w0 * x_smem[x_base + j*4]
                 + w1 * x_smem[x_base + j*4 + 1]
                 + w2 * x_smem[x_base + j*4 + 2]
                 + w3 * x_smem[x_base + j*4 + 3];
        }
    }

    #pragma unroll
    for (int offset = 16; offset >= 1; offset >>= 1)
        acc += __shfl_xor_sync(0xFFFFFFFF, acc, offset);
    if (tx == 0) Y[(long long)bi * M + row] = acc;
}

// Batched RMSNorm: out[bi*dim..] = rmsnorm(x[bi*dim..], w[..], dim, eps)
// 2D grid: blockIdx.x = 1, blockIdx.y = batch index
// Each block (256 threads) handles one vector's normalization.
extern "C" __global__ void rms_norm_batch(
    float* __restrict__ out,
    const float* __restrict__ x,
    const float* __restrict__ w,
    int dim, float eps, int batch_size)
{
    extern __shared__ float smem[];
    int bi = blockIdx.y;
    if (bi >= batch_size) return;
    int tid = threadIdx.x;

    const float* x_bi = x + (long long)bi * dim;
    float* o_bi = out + (long long)bi * dim;

    // Compute sum of squares
    float ss = 0.0f;
    for (int i = tid; i < dim; i += 256) {
        float v = x_bi[i];
        ss += v * v;
    }
    smem[tid] = ss;
    __syncthreads();

    // Warp-level reduction then block-level
    for (int s = 128; s > 0; s >>= 1) {
        if (tid < s) smem[tid] += smem[tid + s];
        __syncthreads();
    }
    float scale = rsqrtf(smem[0] / (float)dim + eps);

    // Apply normalization
    for (int i = tid; i < dim; i += 256) {
        o_bi[i] = x_bi[i] * scale * w[i];
    }
}

// Batched FP32 → FP16 conversion: out[bi*dim..] = fp16(x[bi*dim..])
// 2D grid: blockIdx.x = ceil(dim/256), blockIdx.y = batch index
extern "C" __global__ void fp32_to_fp16_batch(
    __half* __restrict__ out,
    const float* __restrict__ x,
    int dim, int batch_size)
{
    int bi = blockIdx.y;
    if (bi >= batch_size) return;
    int i = blockIdx.x * 256 + threadIdx.x;
    if (i >= dim) return;
    out[(long long)bi * dim + i] = __float2half(x[(long long)bi * dim + i]);
}

// Batched RoPE for Q vectors: apply rotary position encoding to K Q vectors
// positions[bi] gives the position for each vector
// 2D grid: blockIdx.x = ceil(n_heads*half_dim / 256), blockIdx.y = batch index
// LLaMA split-half RoPE: pairs are (q[i], q[i + half_dim])
extern "C" __global__ void rope_q_batch(
    float* __restrict__ q,              // [K × q_dim] contiguous Q vectors
    const int* __restrict__ positions,  // [K] position indices
    int head_dim, float freq_base, int n_heads, int batch_size)
{
    int bi = blockIdx.y;
    if (bi >= batch_size) return;
    int global_id = blockIdx.x * 256 + threadIdx.x;
    int half_dim = head_dim / 2;
    int total_pairs = n_heads * half_dim;
    if (global_id >= total_pairs) return;

    int head = global_id / half_dim;
    int pair = global_id % half_dim;
    int pos = positions[bi];

    // freq = 1.0 / (freq_base ^ (2*pair / head_dim))
    float exponent = (float)(2 * pair) / (float)head_dim;
    float freq = 1.0f / powf(freq_base, exponent);
    float theta = (float)pos * freq;
    float cos_t = cosf(theta);
    float sin_t = sinf(theta);

    int q_dim = n_heads * head_dim;
    float* q_bi = q + (long long)bi * q_dim;
    int idx0 = head * head_dim + pair;
    int idx1 = idx0 + half_dim;

    float q0 = q_bi[idx0];
    float q1 = q_bi[idx1];
    q_bi[idx0] = q0 * cos_t - q1 * sin_t;
    q_bi[idx1] = q0 * sin_t + q1 * cos_t;
}

// Batched RoPE for K vectors (same algorithm, different n_heads → n_kv_heads)
extern "C" __global__ void rope_k_batch(
    float* __restrict__ k,              // [K × kv_dim] contiguous K vectors
    const int* __restrict__ positions,
    int head_dim, float freq_base, int n_kv_heads, int batch_size)
{
    int bi = blockIdx.y;
    if (bi >= batch_size) return;
    int global_id = blockIdx.x * 256 + threadIdx.x;
    int half_dim = head_dim / 2;
    int total_pairs = n_kv_heads * half_dim;
    if (global_id >= total_pairs) return;

    int head = global_id / half_dim;
    int pair = global_id % half_dim;
    int pos = positions[bi];

    float exponent = (float)(2 * pair) / (float)head_dim;
    float freq = 1.0f / powf(freq_base, exponent);
    float theta = (float)pos * freq;
    float cos_t = cosf(theta);
    float sin_t = sinf(theta);

    int kv_dim = n_kv_heads * head_dim;
    float* k_bi = k + (long long)bi * kv_dim;
    int idx0 = head * head_dim + pair;
    int idx1 = idx0 + half_dim;

    float k0 = k_bi[idx0];
    float k1 = k_bi[idx1];
    k_bi[idx0] = k0 * cos_t - k1 * sin_t;
    k_bi[idx1] = k0 * sin_t + k1 * cos_t;
}

// KV cache scatter: write K vectors to scattered positions in KV cache
// cache[positions[bi] * kv_dim ..] = data[bi * kv_dim ..]
// 2D grid: blockIdx.x = ceil(kv_dim/256), blockIdx.y = batch index
extern "C" __global__ void kv_cache_scatter(
    float* __restrict__ cache,           // KV cache layer pointer
    const float* __restrict__ data,      // [K × kv_dim] contiguous vectors
    const int* __restrict__ positions,   // [K] cache position indices
    int kv_dim, int max_seq_len, int batch_size)
{
    int bi = blockIdx.y;
    if (bi >= batch_size) return;
    int i = blockIdx.x * 256 + threadIdx.x;
    if (i >= kv_dim) return;
    int pos = positions[bi];
    cache[(long long)pos * kv_dim + i] = data[(long long)bi * kv_dim + i];
}

// Gather scattered vectors into contiguous buffer.
// dst[bi*dim..] = src[indices[bi]*dim..] for bi in 0..cnt
// 2D grid: blockIdx.x = ceil(dim/256), blockIdx.y = batch index
extern "C" __global__ void gather_vectors(
    float* __restrict__ dst,
    const float* __restrict__ src,
    const int* __restrict__ indices,
    int dim, int cnt)
{
    int bi = blockIdx.y;
    if (bi >= cnt) return;
    int i = blockIdx.x * 256 + threadIdx.x;
    if (i >= dim) return;
    dst[(long long)bi * dim + i] = src[(long long)indices[bi] * dim + i];
}

// Scatter-weighted-add: out[out_tokens[bi]*dim + i] += weights[out_tokens[bi]*topk + ki_vals[bi]] * src[bi*dim + i]
// Accumulates expert outputs back to per-token moe_out with TopK weights.
// Safe without atomicAdd: expert-first ordering ensures one expert at a time.
// 2D grid: blockIdx.x = ceil(dim/256), blockIdx.y = batch index
extern "C" __global__ void scatter_weighted_vadd(
    float* __restrict__ out,
    const float* __restrict__ src,
    const float* __restrict__ weights,
    const int* __restrict__ out_tokens,
    const int* __restrict__ ki_vals,
    int dim, int topk, int cnt)
{
    int bi = blockIdx.y;
    if (bi >= cnt) return;
    int i = blockIdx.x * 256 + threadIdx.x;
    if (i >= dim) return;
    int t = out_tokens[bi];
    int ki = ki_vals[bi];
    float w = weights[t * topk + ki];
    out[(long long)t * dim + i] += w * src[(long long)bi * dim + i];
}

// Fused gate+up gather-GEMV: computes BOTH gate and up outputs in 1 launch.
// Loads input vector once into shared memory, then reads both weight matrices.
// Halves kernel launch count per expert (2 launches → 1).
// Y_gate[bi*M + row] = W_gate[M×K] @ X[indices[bi]*K + :]
// Y_up[bi*M + row]   = W_up[M×K]   @ X[indices[bi]*K + :]
extern "C" __global__ void q4_0_gemv_fused_gate_up_gather(
    float* __restrict__ Y_gate,
    float* __restrict__ Y_up,
    const unsigned char* __restrict__ W_gate,
    const unsigned char* __restrict__ W_up,
    const float* __restrict__ X,
    const int* __restrict__ indices,
    int M, int K, int batch_size)
{
    extern __shared__ float x_smem[];
    int tid = threadIdx.x;
    int n_blocks_per_row = K >> 5;
    int bi = blockIdx.y;

    // Load input vector ONCE into shared memory (shared by gate and up)
    const float* x_bi = X + (long long)indices[bi] * K;
    for (int idx = tid; idx < K; idx += 256) {
        int padded = idx + (idx >> 5);
        x_smem[padded] = __ldg(&x_bi[idx]);
    }
    __syncthreads();

    int tx = tid & 31;
    int ty = tid >> 5;
    int row = blockIdx.x * 8 + ty;
    if (row >= M) return;

    // --- Gate GEMV ---
    {
        const unsigned char* W_row = W_gate + (long long)row * n_blocks_per_row * 18;
        float acc = 0.0f;
        for (int b = tx; b < n_blocks_per_row; b += 32) {
            const unsigned char* block_ptr = W_row + b * 18;
            float scale = __half2float(*reinterpret_cast<const __half*>(block_ptr));
            float neg8_scale = scale * (-8.0f);
            int x_base = b * 33;
            const unsigned short* data_u16 = reinterpret_cast<const unsigned short*>(block_ptr + 2);
            #pragma unroll
            for (int j = 0; j < 8; j++) {
                unsigned short val = __ldg(&data_u16[j]);
                unsigned char b0 = val & 0xFF;
                unsigned char b1 = val >> 8;
                float w0 = (float)(b0 & 0xF) * scale + neg8_scale;
                float w1 = (float)(b0 >> 4)  * scale + neg8_scale;
                float w2 = (float)(b1 & 0xF) * scale + neg8_scale;
                float w3 = (float)(b1 >> 4)  * scale + neg8_scale;
                acc += w0 * x_smem[x_base + j*4]
                     + w1 * x_smem[x_base + j*4 + 1]
                     + w2 * x_smem[x_base + j*4 + 2]
                     + w3 * x_smem[x_base + j*4 + 3];
            }
        }
        #pragma unroll
        for (int offset = 16; offset >= 1; offset >>= 1)
            acc += __shfl_xor_sync(0xFFFFFFFF, acc, offset);
        if (tx == 0) Y_gate[(long long)bi * M + row] = acc;
    }

    // --- Up GEMV (same input, different weights) ---
    {
        const unsigned char* W_row = W_up + (long long)row * n_blocks_per_row * 18;
        float acc = 0.0f;
        for (int b = tx; b < n_blocks_per_row; b += 32) {
            const unsigned char* block_ptr = W_row + b * 18;
            float scale = __half2float(*reinterpret_cast<const __half*>(block_ptr));
            float neg8_scale = scale * (-8.0f);
            int x_base = b * 33;
            const unsigned short* data_u16 = reinterpret_cast<const unsigned short*>(block_ptr + 2);
            #pragma unroll
            for (int j = 0; j < 8; j++) {
                unsigned short val = __ldg(&data_u16[j]);
                unsigned char b0 = val & 0xFF;
                unsigned char b1 = val >> 8;
                float w0 = (float)(b0 & 0xF) * scale + neg8_scale;
                float w1 = (float)(b0 >> 4)  * scale + neg8_scale;
                float w2 = (float)(b1 & 0xF) * scale + neg8_scale;
                float w3 = (float)(b1 >> 4)  * scale + neg8_scale;
                acc += w0 * x_smem[x_base + j*4]
                     + w1 * x_smem[x_base + j*4 + 1]
                     + w2 * x_smem[x_base + j*4 + 2]
                     + w3 * x_smem[x_base + j*4 + 3];
            }
        }
        #pragma unroll
        for (int offset = 16; offset >= 1; offset >>= 1)
            acc += __shfl_xor_sync(0xFFFFFFFF, acc, offset);
        if (tx == 0) Y_up[(long long)bi * M + row] = acc;
    }
}

// Batched softmax + TopK: process K tokens in 1 launch (K blocks, 1 thread each)
// Same algorithm as softmax_topk_kernel but batched across tokens.
// Input: router_logits[K × n_experts] FP16, one row per token
// Output: expert_ids[K × topk] (int32), expert_weights[K × topk] (float32)
extern "C" __global__ void softmax_topk_batch(
    int* __restrict__ expert_ids,
    float* __restrict__ expert_weights,
    const __half* __restrict__ router_logits,
    int n_experts, int topk, int batch_size)
{
    int bi = blockIdx.x;
    if (bi >= batch_size) return;
    if (threadIdx.x != 0) return;

    const __half* logits = router_logits + (long long)bi * n_experts;
    int* ids_out = expert_ids + bi * topk;
    float* wts_out = expert_weights + bi * topk;

    float scores[256];
    float max_val = -1e30f;
    for (int e = 0; e < n_experts; e++) {
        scores[e] = __half2float(logits[e]);
        max_val = fmaxf(max_val, scores[e]);
    }
    float sum_exp = 0.0f;
    for (int e = 0; e < n_experts; e++) {
        scores[e] = expf(scores[e] - max_val);
        sum_exp += scores[e];
    }
    for (int e = 0; e < n_experts; e++) scores[e] /= sum_exp;

    for (int k = 0; k < topk; k++) {
        int best_e = 0;
        float best_w = -1.0f;
        for (int e = 0; e < n_experts; e++) {
            if (scores[e] > best_w) { best_e = e; best_w = scores[e]; }
        }
        ids_out[k] = best_e;
        wts_out[k] = best_w;
        scores[best_e] = -1.0f;
    }
    float wsum = 0.0f;
    for (int k = 0; k < topk; k++) wsum += wts_out[k];
    if (wsum > 0.0f) for (int k = 0; k < topk; k++) wts_out[k] /= wsum;
}

// GPU-side expert routing: builds gather/scatter index arrays from softmax_topk output.
// Eliminates CPU-side sync + sorting + HtoD upload per layer.
// Single block kernel (1 block, 256 threads). Total work = K*topk ≤ 2048.
//
// Input:  expert_ids[K*topk] (int32) from softmax_topk
// Output: expert_count[n_experts]  — tokens per expert
//         expert_offset[n_experts] — exclusive prefix sum of counts
//         gather_idx[K*topk]       — token index for gather (flat, sorted by expert)
//         scatter_t[K*topk]        — token index for scatter output
//         scatter_ki[K*topk]       — ki index for scatter weight lookup
extern "C" __global__ void build_expert_routing(
    int* __restrict__ expert_count,
    int* __restrict__ expert_offset,
    int* __restrict__ gather_idx,
    int* __restrict__ scatter_t,
    int* __restrict__ scatter_ki,
    const int* __restrict__ expert_ids,
    int K, int topk, int n_experts)
{
    int tid = threadIdx.x;
    int total_slots = K * topk;

    // Phase 1: Zero and count in shared memory
    __shared__ int s_count[256]; // max 256 experts
    __shared__ int s_offset[256];
    for (int e = tid; e < n_experts; e += blockDim.x) {
        s_count[e] = 0;
    }
    __syncthreads();

    for (int i = tid; i < total_slots; i += blockDim.x) {
        int eid = expert_ids[i];
        if (eid >= 0 && eid < n_experts) {
            atomicAdd(&s_count[eid], 1);
        }
    }
    __syncthreads();

    // Phase 2: Prefix sum (single thread, n_experts=96 is trivial)
    if (tid == 0) {
        int sum = 0;
        for (int e = 0; e < n_experts; e++) {
            s_offset[e] = sum;
            sum += s_count[e];
        }
    }
    __syncthreads();

    // Write counts and offsets to global memory
    for (int e = tid; e < n_experts; e += blockDim.x) {
        expert_count[e] = s_count[e];
        expert_offset[e] = s_offset[e];
    }

    // Phase 3: Build flat index arrays using atomic insertion
    // Reset counts as insertion counters
    for (int e = tid; e < n_experts; e += blockDim.x) {
        s_count[e] = 0;
    }
    __syncthreads();

    for (int i = tid; i < total_slots; i += blockDim.x) {
        int eid = expert_ids[i];
        if (eid >= 0 && eid < n_experts) {
            int t = i / topk;
            int ki = i % topk;
            int pos = s_offset[eid] + atomicAdd(&s_count[eid], 1);
            gather_idx[pos] = t;
            scatter_t[pos] = t;
            scatter_ki[pos] = ki;
        }
    }
}

// GPU-side weighted vector add: out[i] += weights[ki] * x[i]
// Reads the scalar weight from device memory at index `ki`.
// This eliminates the need to download TopK weights to CPU.
extern "C" __global__ void weighted_vadd_device(
    float* __restrict__ out,
    const float* __restrict__ x,
    const float* __restrict__ weights,
    int ki, int n)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float w = weights[ki];
    out[i] += w * x[i];
}

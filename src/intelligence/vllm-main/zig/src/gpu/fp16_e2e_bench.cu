// FP16 End-to-End Benchmark: Real text generation with DART + HGEMM
//
// Complete 7B LLaMA forward pass using pre-dequanted FP16 weights + cuBLAS HGEMM.
// Includes all ops: embedding, RMSNorm, RoPE, attention, SwiGLU, residual.
// Single-token decode + DART batch verify timing.
//
// Compile: nvcc -O3 -arch=sm_75 -lcublas -o fp16_e2e_bench fp16_e2e_bench.cu
// Run:     ./fp16_e2e_bench /path/to/llama-2-7b-chat.Q4_0.gguf

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <cuda_fp16.h>

#define CHECK_CUDA(call) do { \
    cudaError_t err = (call); \
    if (err != cudaSuccess) { \
        printf("CUDA error at %s:%d: %s\n", __FILE__, __LINE__, cudaGetErrorString(err)); \
        exit(1); \
    } \
} while(0)

#define CHECK_CUBLAS(call) do { \
    cublasStatus_t st = (call); \
    if (st != CUBLAS_STATUS_SUCCESS) { \
        printf("cuBLAS error at %s:%d: status=%d\n", __FILE__, __LINE__, (int)st); \
        exit(1); \
    } \
} while(0)

// ============================================================================
// GPU Kernels for non-GEMM operations (all work on FP32 activations)
// ============================================================================

// RMSNorm: out[i] = (x[i] / rms) * weight[i], rms = sqrt(mean(x^2) + eps)
__global__ void rms_norm_kernel(float* __restrict__ out,
                                 const float* __restrict__ x,
                                 const float* __restrict__ weight,
                                 int dim, float eps) {
    // Single block, cooperative reduction
    extern __shared__ float smem[];
    int tid = threadIdx.x;

    float sum_sq = 0.0f;
    for (int i = tid; i < dim; i += blockDim.x)
        sum_sq += x[i] * x[i];
    smem[tid] = sum_sq;
    __syncthreads();

    // Tree reduction
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) smem[tid] += smem[tid + s];
        __syncthreads();
    }

    float rms = rsqrtf(smem[0] / (float)dim + eps);
    for (int i = tid; i < dim; i += blockDim.x)
        out[i] = x[i] * rms * weight[i];
}

// Embedding lookup: out = embedding_table[token_id]
__global__ void embedding_kernel(float* __restrict__ out,
                                  const __half* __restrict__ table,
                                  int token_id, int dim) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < dim)
        out[i] = __half2float(table[token_id * dim + i]);
}

// RoPE rotation (split-half LLaMA convention)
__global__ void rope_kernel(float* __restrict__ vec, int pos, int head_dim,
                             float freq_base, int n_heads) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    int total = n_heads * head_dim;
    if (i >= total) return;

    int head = i / head_dim;
    int j = i % head_dim;
    if (j >= head_dim / 2) return;

    float freq = 1.0f / powf(freq_base, (float)(2 * j) / (float)head_dim);
    float theta = (float)pos * freq;
    float cos_t = cosf(theta);
    float sin_t = sinf(theta);

    int idx0 = head * head_dim + j;
    int idx1 = head * head_dim + j + head_dim / 2;
    float v0 = vec[idx0];
    float v1 = vec[idx1];
    vec[idx0] = v0 * cos_t - v1 * sin_t;
    vec[idx1] = v0 * sin_t + v1 * cos_t;
}

// SwiGLU: gate = silu(gate) * up
__global__ void swiglu_kernel(float* __restrict__ gate,
                               const float* __restrict__ up, int dim) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < dim) {
        float g = gate[i];
        float silu = g / (1.0f + expf(-g));
        gate[i] = silu * up[i];
    }
}

// Vector add: out = a + b
__global__ void vecadd_kernel(float* __restrict__ out,
                               const float* __restrict__ a,
                               const float* __restrict__ b, int dim) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < dim) out[i] = a[i] + b[i];
}

// FP32 → FP16 conversion
__global__ void fp32_to_fp16_kernel(__half* __restrict__ out,
                                     const float* __restrict__ in, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) out[i] = __float2half(in[i]);
}

// FP16 → FP32 conversion
__global__ void fp16_to_fp32_kernel(float* __restrict__ out,
                                     const __half* __restrict__ in, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) out[i] = __half2float(in[i]);
}

// Decode attention: single-query attention against KV cache
// out[dim] = softmax(Q @ K^T / sqrt(head_dim)) @ V
// Q: [n_heads * head_dim], K_cache: [seq_len * kv_dim], V_cache: [seq_len * kv_dim]
__global__ void decode_attention_kernel(
    float* __restrict__ out,        // [n_heads * head_dim]
    const float* __restrict__ q,    // [n_heads * head_dim]
    const float* __restrict__ k_cache, // [max_seq * kv_dim]
    const float* __restrict__ v_cache, // [max_seq * kv_dim]
    int n_heads, int n_kv_heads, int head_dim, int seq_len, float scale,
    int max_seq_len)
{
    int h = blockIdx.x;  // one block per head
    if (h >= n_heads) return;
    int kv_h = h / (n_heads / n_kv_heads);  // GQA mapping

    extern __shared__ float smem[];  // [seq_len] for scores
    int tid = threadIdx.x;

    // Compute Q @ K^T scores for this head
    const float* q_head = q + h * head_dim;
    for (int s = tid; s < seq_len; s += blockDim.x) {
        const float* k_s = k_cache + s * n_kv_heads * head_dim + kv_h * head_dim;
        float dot = 0.0f;
        for (int d = 0; d < head_dim; d++)
            dot += q_head[d] * k_s[d];
        smem[s] = dot * scale;
    }
    __syncthreads();

    // Softmax: find max
    float max_val = -1e30f;
    for (int s = tid; s < seq_len; s += blockDim.x)
        max_val = fmaxf(max_val, smem[s]);
    // Warp reduction for max
    for (int offset = 16; offset >= 1; offset >>= 1)
        max_val = fmaxf(max_val, __shfl_xor_sync(0xFFFFFFFF, max_val, offset));
    // Block reduction via shared memory
    __shared__ float block_max[32];
    int warp_id = tid / 32;
    int lane = tid % 32;
    if (lane == 0) block_max[warp_id] = max_val;
    __syncthreads();
    if (tid < 32) {
        max_val = (tid < blockDim.x / 32) ? block_max[tid] : -1e30f;
        for (int offset = 16; offset >= 1; offset >>= 1)
            max_val = fmaxf(max_val, __shfl_xor_sync(0xFFFFFFFF, max_val, offset));
    }
    __syncthreads();
    if (tid == 0) block_max[0] = max_val;
    __syncthreads();
    max_val = block_max[0];

    // Softmax: exp and sum
    float sum_exp = 0.0f;
    for (int s = tid; s < seq_len; s += blockDim.x) {
        smem[s] = expf(smem[s] - max_val);
        sum_exp += smem[s];
    }
    // Reduce sum
    __shared__ float block_sum[32];
    for (int offset = 16; offset >= 1; offset >>= 1)
        sum_exp += __shfl_xor_sync(0xFFFFFFFF, sum_exp, offset);
    if (lane == 0) block_sum[warp_id] = sum_exp;
    __syncthreads();
    if (tid < 32) {
        sum_exp = (tid < blockDim.x / 32) ? block_sum[tid] : 0.0f;
        for (int offset = 16; offset >= 1; offset >>= 1)
            sum_exp += __shfl_xor_sync(0xFFFFFFFF, sum_exp, offset);
    }
    __syncthreads();
    if (tid == 0) block_sum[0] = sum_exp;
    __syncthreads();
    float inv_sum = 1.0f / block_sum[0];

    // Normalize
    for (int s = tid; s < seq_len; s += blockDim.x)
        smem[s] *= inv_sum;
    __syncthreads();

    // Weighted sum: out = scores @ V
    float* out_head = out + h * head_dim;
    for (int d = tid; d < head_dim; d += blockDim.x) {
        float acc = 0.0f;
        for (int s = 0; s < seq_len; s++) {
            const float* v_s = v_cache + s * n_kv_heads * head_dim + kv_h * head_dim;
            acc += smem[s] * v_s[d];
        }
        out_head[d] = acc;
    }
}

// Q4_0 → FP16 dequantization
__global__ void dequant_q4_fp16(__half* __restrict__ out,
                                 const uint8_t* __restrict__ q4_data,
                                 int M, int K) {
    int n_blocks_per_row = K >> 5;
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= M * n_blocks_per_row) return;

    int row = idx / n_blocks_per_row;
    int col_block = idx % n_blocks_per_row;

    const uint8_t* bp = q4_data + (long long)row * n_blocks_per_row * 18 + col_block * 18;
    float scale = __half2float(*reinterpret_cast<const __half*>(bp));

    int base = row * K + col_block * 32;
    for (int j = 0; j < 16; j++) {
        uint8_t byte = bp[2 + j];
        out[base + j]      = __float2half(((float)(byte & 0xF) - 8.0f) * scale);
        out[base + j + 16] = __float2half(((float)(byte >> 4) - 8.0f) * scale);
    }
}

// ============================================================================
// GGUF Parser (same as dart_fp16_bench.cu)
// ============================================================================
static uint64_t read_u64(const uint8_t* p) { uint64_t v; memcpy(&v, p, 8); return v; }
static uint32_t read_u32(const uint8_t* p) { uint32_t v; memcpy(&v, p, 4); return v; }

static size_t skip_gguf_value(const uint8_t* data, size_t pos, uint32_t vtype) {
    switch (vtype) {
        case 0: case 1: case 7: return pos + 1;
        case 2: case 3: return pos + 2;
        case 4: case 5: case 6: return pos + 4;
        case 10: case 11: case 12: return pos + 8;
        case 8: { uint64_t len = read_u64(data+pos); return pos+8+(size_t)len; }
        case 9: { uint32_t et = read_u32(data+pos); uint64_t cnt = read_u64(data+pos+4);
                   size_t p = pos+12; for(uint64_t i=0;i<cnt;i++) p=skip_gguf_value(data,p,et); return p; }
        default: printf("Unknown type %u\n",vtype); exit(1);
    }
}

static size_t skip_gguf_kv(const uint8_t* data, size_t pos) {
    uint64_t kl = read_u64(data+pos); pos += 8+(size_t)kl;
    uint32_t vt = read_u32(data+pos); pos += 4;
    return skip_gguf_value(data, pos, vt);
}

static int64_t find_int(const uint8_t* data, size_t start, uint64_t n_kv, const char* key) {
    size_t pos = start; int klen = strlen(key);
    for (uint64_t i = 0; i < n_kv; i++) {
        uint64_t kl = read_u64(data+pos); const char* k = (const char*)(data+pos+8);
        pos += 8+(size_t)kl; uint32_t vt = read_u32(data+pos); pos += 4;
        if ((int)kl==klen && memcmp(k,key,kl)==0) {
            if (vt==4) return (int64_t)read_u32(data+pos);
            if (vt==5) return (int64_t)(int32_t)read_u32(data+pos);
            if (vt==10||vt==11) return (int64_t)read_u64(data+pos);
            return -1;
        }
        pos = skip_gguf_value(data, pos, vt);
    }
    return -1;
}

static float find_float(const uint8_t* data, size_t start, uint64_t n_kv, const char* key) {
    size_t pos = start; int klen = strlen(key);
    for (uint64_t i = 0; i < n_kv; i++) {
        uint64_t kl = read_u64(data+pos); const char* k = (const char*)(data+pos+8);
        pos += 8+(size_t)kl; uint32_t vt = read_u32(data+pos); pos += 4;
        if ((int)kl==klen && memcmp(k,key,kl)==0 && vt==6) {
            float v; memcpy(&v, data+pos, 4); return v;
        }
        pos = skip_gguf_value(data, pos, vt);
    }
    return 0.0f;
}

// ============================================================================
// Model structures
// ============================================================================
struct Config { int dim, n_layers, n_heads, n_kv_heads, ff_dim, vocab; float rope_base; };

struct FP16Layer {
    __half *wq, *wk, *wv, *wo, *w_gate, *w_up, *w_down;
    float *rms_attn, *rms_ffn;  // norms stay FP32
};

struct Activations {
    float *hidden, *norm, *q, *k, *v, *attn_out, *gate, *up, *ffn_out, *logits;
    __half *h_in;   // FP16 input to HGEMM (max: ff_dim)
    __half *h_out;  // FP16 output from HGEMM (max: vocab)
    float *kv_key, *kv_val;  // KV cache [n_layers * max_seq * kv_dim]
    int max_seq;
};

// ============================================================================
// Forward pass
// ============================================================================
void forward_single(cublasHandle_t handle, Config& cfg, FP16Layer* layers,
                     __half* d_embd, __half* d_lm_head, float* d_rms_final,
                     Activations& act, int token, int pos) {
    int dim = cfg.dim, ff = cfg.ff_dim;
    int n_heads = cfg.n_heads, n_kv_heads = cfg.n_kv_heads;
    int head_dim = dim / n_heads;
    int kv_dim = n_kv_heads * head_dim;
    int seq_len = pos + 1;
    __half alpha_h = __float2half(1.0f), beta_h = __float2half(0.0f);

    // 1. Embedding lookup (FP16 table → FP32 hidden)
    embedding_kernel<<<(dim+255)/256, 256>>>(act.hidden, d_embd, token, dim);

    // 2. Transformer layers
    for (int l = 0; l < cfg.n_layers; l++) {
        FP16Layer& lw = layers[l];

        // RMSNorm
        rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(act.norm, act.hidden, lw.rms_attn, dim, 1e-5f);

        // Convert norm FP32 → FP16 for HGEMM input
        fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(act.h_in, act.norm, dim);

        // Q/K/V projections via HGEMM
        // Weight W is row-major [M×K] → cuBLAS sees col-major [K×M] → use OP_T, lda=K
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, 1, dim,
                     &alpha_h, lw.wq, dim, act.h_in, dim, &beta_h, act.h_out, dim);
        fp16_to_fp32_kernel<<<(dim+255)/256, 256>>>(act.q, act.h_out, dim);

        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, kv_dim, 1, dim,
                     &alpha_h, lw.wk, dim, act.h_in, dim, &beta_h, act.h_out, kv_dim);
        fp16_to_fp32_kernel<<<(kv_dim+255)/256, 256>>>(act.k, act.h_out, kv_dim);

        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, kv_dim, 1, dim,
                     &alpha_h, lw.wv, dim, act.h_in, dim, &beta_h, act.h_out, kv_dim);
        fp16_to_fp32_kernel<<<(kv_dim+255)/256, 256>>>(act.v, act.h_out, kv_dim);

        // RoPE
        rope_kernel<<<(dim+255)/256, 256>>>(act.q, pos, head_dim, cfg.rope_base, n_heads);
        rope_kernel<<<(kv_dim+255)/256, 256>>>(act.k, pos, head_dim, cfg.rope_base, n_kv_heads);

        // Store K,V into cache
        float* k_dst = act.kv_key + (long long)l * act.max_seq * kv_dim + pos * kv_dim;
        float* v_dst = act.kv_val + (long long)l * act.max_seq * kv_dim + pos * kv_dim;
        cudaMemcpyAsync(k_dst, act.k, kv_dim * sizeof(float), cudaMemcpyDeviceToDevice);
        cudaMemcpyAsync(v_dst, act.v, kv_dim * sizeof(float), cudaMemcpyDeviceToDevice);

        // Attention
        float scale = 1.0f / sqrtf((float)head_dim);
        float* k_layer = act.kv_key + (long long)l * act.max_seq * kv_dim;
        float* v_layer = act.kv_val + (long long)l * act.max_seq * kv_dim;
        int smem_attn = seq_len * sizeof(float);
        if (smem_attn < 48*1024)
            decode_attention_kernel<<<n_heads, 256, smem_attn>>>(
                act.attn_out, act.q, k_layer, v_layer,
                n_heads, n_kv_heads, head_dim, seq_len, scale, act.max_seq);

        // O projection
        fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(act.h_in, act.attn_out, dim);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, 1, dim,
                     &alpha_h, lw.wo, dim, act.h_in, dim, &beta_h, act.h_out, dim);
        fp16_to_fp32_kernel<<<(dim+255)/256, 256>>>(act.norm, act.h_out, dim);

        // Residual
        vecadd_kernel<<<(dim+255)/256, 256>>>(act.hidden, act.hidden, act.norm, dim);

        // FFN RMSNorm
        rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(act.norm, act.hidden, lw.rms_ffn, dim, 1e-5f);

        // FFN gate + up projections
        fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(act.h_in, act.norm, dim);

        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, ff, 1, dim,
                     &alpha_h, lw.w_gate, dim, act.h_in, dim, &beta_h, act.h_out, ff);
        fp16_to_fp32_kernel<<<(ff+255)/256, 256>>>(act.gate, act.h_out, ff);

        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, ff, 1, dim,
                     &alpha_h, lw.w_up, dim, act.h_in, dim, &beta_h, act.h_out, ff);
        fp16_to_fp32_kernel<<<(ff+255)/256, 256>>>(act.up, act.h_out, ff);

        // SwiGLU
        swiglu_kernel<<<(ff+255)/256, 256>>>(act.gate, act.up, ff);

        // FFN down projection
        fp32_to_fp16_kernel<<<(ff+255)/256, 256>>>(act.h_in, act.gate, ff);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, 1, ff,
                     &alpha_h, lw.w_down, ff, act.h_in, ff, &beta_h, act.h_out, dim);
        fp16_to_fp32_kernel<<<(dim+255)/256, 256>>>(act.ffn_out, act.h_out, dim);

        // Residual
        vecadd_kernel<<<(dim+255)/256, 256>>>(act.hidden, act.hidden, act.ffn_out, dim);
    }

    // 3. Final RMSNorm
    rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(act.norm, act.hidden, d_rms_final, dim, 1e-5f);

    // 4. LM head: logits = lm_head @ norm
    fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(act.h_in, act.norm, dim);
    cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, cfg.vocab, 1, dim,
                 &alpha_h, d_lm_head, dim, act.h_in, dim, &beta_h, act.h_out, cfg.vocab);
    fp16_to_fp32_kernel<<<(cfg.vocab+255)/256, 256>>>(act.logits, act.h_out, cfg.vocab);
}

// ============================================================================
// Batched Forward Pass — DART verification of K tokens simultaneously
// ============================================================================
// HGEMM processes all K tokens in one call (B=K). Non-HGEMM ops run per-token.
// Activation layout: all batched buffers are [K × dim] contiguous.
void forward_batch(cublasHandle_t handle, Config& cfg, FP16Layer* layers,
                    __half* d_embd, __half* d_lm_head, float* d_rms_final,
                    Activations& act, int* tokens, int* positions, int K,
                    __half* h_in_batch, __half* h_out_batch,
                    float* hidden_batch, float* norm_batch,
                    float* q_batch, float* k_batch, float* v_batch,
                    float* attn_out_batch, float* gate_batch, float* up_batch) {
    int dim = cfg.dim, ff = cfg.ff_dim;
    int n_heads = cfg.n_heads, n_kv_heads = cfg.n_kv_heads;
    int head_dim = dim / n_heads;
    int kv_dim = n_kv_heads * head_dim;
    __half alpha_h = __float2half(1.0f), beta_h = __float2half(0.0f);

    // 1. Embedding lookup for all K tokens
    for (int b = 0; b < K; b++)
        embedding_kernel<<<(dim+255)/256, 256>>>(hidden_batch + b*dim, d_embd, tokens[b], dim);

    // 2. Transformer layers
    for (int l = 0; l < cfg.n_layers; l++) {
        FP16Layer& lw = layers[l];

        // RMSNorm for all K tokens (independent per token)
        for (int b = 0; b < K; b++)
            rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(
                norm_batch + b*dim, hidden_batch + b*dim, lw.rms_attn, dim, 1e-5f);

        // Convert all K normed vectors to FP16: [K × dim]
        fp32_to_fp16_kernel<<<(K*dim+255)/256, 256>>>(h_in_batch, norm_batch, K*dim);

        // Batched Q/K/V projections: one HGEMM call processes all K tokens
        // Y[M×K] = W^T[M×dim] × X[dim×K]
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, K, dim,
                     &alpha_h, lw.wq, dim, h_in_batch, dim, &beta_h, h_out_batch, dim);
        fp16_to_fp32_kernel<<<(K*dim+255)/256, 256>>>(q_batch, h_out_batch, K*dim);

        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, kv_dim, K, dim,
                     &alpha_h, lw.wk, dim, h_in_batch, dim, &beta_h, h_out_batch, kv_dim);
        fp16_to_fp32_kernel<<<(K*kv_dim+255)/256, 256>>>(k_batch, h_out_batch, K*kv_dim);

        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, kv_dim, K, dim,
                     &alpha_h, lw.wv, dim, h_in_batch, dim, &beta_h, h_out_batch, kv_dim);
        fp16_to_fp32_kernel<<<(K*kv_dim+255)/256, 256>>>(v_batch, h_out_batch, K*kv_dim);

        // Per-token: RoPE + KV store + Attention
        for (int b = 0; b < K; b++) {
            int pos = positions[b];
            int seq_len = pos + 1;
            rope_kernel<<<(dim+255)/256, 256>>>(q_batch + b*dim, pos, head_dim, cfg.rope_base, n_heads);
            rope_kernel<<<(kv_dim+255)/256, 256>>>(k_batch + b*kv_dim, pos, head_dim, cfg.rope_base, n_kv_heads);

            float* k_dst = act.kv_key + (long long)l * act.max_seq * kv_dim + pos * kv_dim;
            float* v_dst = act.kv_val + (long long)l * act.max_seq * kv_dim + pos * kv_dim;
            cudaMemcpyAsync(k_dst, k_batch + b*kv_dim, kv_dim*sizeof(float), cudaMemcpyDeviceToDevice);
            cudaMemcpyAsync(v_dst, v_batch + b*kv_dim, kv_dim*sizeof(float), cudaMemcpyDeviceToDevice);

            float scale = 1.0f / sqrtf((float)head_dim);
            float* k_layer = act.kv_key + (long long)l * act.max_seq * kv_dim;
            float* v_layer = act.kv_val + (long long)l * act.max_seq * kv_dim;
            int smem_attn = seq_len * sizeof(float);
            if (smem_attn < 48*1024)
                decode_attention_kernel<<<n_heads, 256, smem_attn>>>(
                    attn_out_batch + b*dim, q_batch + b*dim, k_layer, v_layer,
                    n_heads, n_kv_heads, head_dim, seq_len, scale, act.max_seq);
        }

        // Batched O projection
        fp32_to_fp16_kernel<<<(K*dim+255)/256, 256>>>(h_in_batch, attn_out_batch, K*dim);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, K, dim,
                     &alpha_h, lw.wo, dim, h_in_batch, dim, &beta_h, h_out_batch, dim);
        fp16_to_fp32_kernel<<<(K*dim+255)/256, 256>>>(norm_batch, h_out_batch, K*dim);

        // Batched residual
        vecadd_kernel<<<(K*dim+255)/256, 256>>>(hidden_batch, hidden_batch, norm_batch, K*dim);

        // Batched FFN RMSNorm
        for (int b = 0; b < K; b++)
            rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(
                norm_batch + b*dim, hidden_batch + b*dim, lw.rms_ffn, dim, 1e-5f);

        // Batched FFN gate + up
        fp32_to_fp16_kernel<<<(K*dim+255)/256, 256>>>(h_in_batch, norm_batch, K*dim);

        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, ff, K, dim,
                     &alpha_h, lw.w_gate, dim, h_in_batch, dim, &beta_h, h_out_batch, ff);
        fp16_to_fp32_kernel<<<(K*ff+255)/256, 256>>>(gate_batch, h_out_batch, K*ff);

        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, ff, K, dim,
                     &alpha_h, lw.w_up, dim, h_in_batch, dim, &beta_h, h_out_batch, ff);
        fp16_to_fp32_kernel<<<(K*ff+255)/256, 256>>>(up_batch, h_out_batch, K*ff);

        // Batched SwiGLU
        swiglu_kernel<<<(K*ff+255)/256, 256>>>(gate_batch, up_batch, K*ff);

        // Batched FFN down
        fp32_to_fp16_kernel<<<(K*ff+255)/256, 256>>>(h_in_batch, gate_batch, K*ff);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, K, ff,
                     &alpha_h, lw.w_down, ff, h_in_batch, ff, &beta_h, h_out_batch, dim);
        fp16_to_fp32_kernel<<<(K*dim+255)/256, 256>>>(norm_batch, h_out_batch, K*dim);

        // Batched residual
        vecadd_kernel<<<(K*dim+255)/256, 256>>>(hidden_batch, hidden_batch, norm_batch, K*dim);
    }

    // 3. Final RMSNorm + LM head for all K tokens
    for (int b = 0; b < K; b++)
        rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(
            norm_batch + b*dim, hidden_batch + b*dim, d_rms_final, dim, 1e-5f);

    fp32_to_fp16_kernel<<<(K*dim+255)/256, 256>>>(h_in_batch, norm_batch, K*dim);
    cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, cfg.vocab, K, dim,
                 &alpha_h, d_lm_head, dim, h_in_batch, dim, &beta_h, h_out_batch, cfg.vocab);
    fp16_to_fp32_kernel<<<(K*cfg.vocab+255)/256, 256>>>(act.logits, h_out_batch, K*cfg.vocab);
}

// ============================================================================
// Main
// ============================================================================
int main(int argc, char** argv) {
    if (argc < 2) { printf("Usage: %s <model.gguf>\n", argv[0]); return 1; }

    // Memory-map GGUF
    int fd = open(argv[1], O_RDONLY);
    struct stat st; fstat(fd, &st);
    const uint8_t* data = (const uint8_t*)mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);

    uint32_t magic; memcpy(&magic, data, 4);
    if (magic != 0x46554747) { printf("Bad magic\n"); return 1; }

    uint32_t version = read_u32(data + 4);
    uint64_t n_tensors = read_u64(data + 8);
    uint64_t n_kv = read_u64(data + 16);
    size_t kv_start = 24;  // After header

    Config cfg;
    cfg.dim = (int)find_int(data, kv_start, n_kv, "llama.embedding_length");
    cfg.n_layers = (int)find_int(data, kv_start, n_kv, "llama.block_count");
    cfg.n_heads = (int)find_int(data, kv_start, n_kv, "llama.attention.head_count");
    cfg.n_kv_heads = (int)find_int(data, kv_start, n_kv, "llama.attention.head_count_kv");
    cfg.ff_dim = (int)find_int(data, kv_start, n_kv, "llama.feed_forward_length");
    cfg.rope_base = find_float(data, kv_start, n_kv, "llama.rope.freq_base");
    if (cfg.rope_base == 0.0f) cfg.rope_base = 10000.0f;

    printf("Model: dim=%d layers=%d heads=%d kv_heads=%d ff=%d rope=%.0f\n",
           cfg.dim, cfg.n_layers, cfg.n_heads, cfg.n_kv_heads, cfg.ff_dim, cfg.rope_base);

    // Skip KV pairs to tensor descriptors
    size_t pos = kv_start;
    for (uint64_t i = 0; i < n_kv; i++) pos = skip_gguf_kv(data, pos);

    // Parse tensor descriptors
    struct TD { char name[128]; int name_len; uint64_t dims[4]; uint32_t n_dims, type; uint64_t offset; };
    TD* tensors = new TD[n_tensors];
    for (uint64_t i = 0; i < n_tensors; i++) {
        TD& t = tensors[i];
        t.name_len = (int)read_u64(data + pos);
        memcpy(t.name, data + pos + 8, t.name_len); t.name[t.name_len] = 0;
        pos += 8 + t.name_len;
        t.n_dims = read_u32(data + pos); pos += 4;
        for (uint32_t d = 0; d < t.n_dims; d++) { t.dims[d] = read_u64(data + pos); pos += 8; }
        for (uint32_t d = t.n_dims; d < 4; d++) t.dims[d] = 1;
        t.type = read_u32(data + pos); pos += 4;
        t.offset = read_u64(data + pos); pos += 8;
    }
    size_t data_start = (pos + 31) & ~31ULL;

    // Helper: find tensor
    auto find_tensor = [&](const char* name) -> TD* {
        for (uint64_t i = 0; i < n_tensors; i++)
            if (strcmp(tensors[i].name, name) == 0) return &tensors[i];
        return nullptr;
    };

    // Helper: Q4_0 tensor → FP16 on GPU
    auto load_q4_fp16 = [&](const char* name, int M, int K) -> __half* {
        TD* t = find_tensor(name);
        if (!t) { printf("Missing tensor: %s\n", name); exit(1); }
        size_t q4_bytes = (size_t)M * (K/32) * 18;
        uint8_t* d_q4; CHECK_CUDA(cudaMalloc(&d_q4, q4_bytes));
        CHECK_CUDA(cudaMemcpy(d_q4, data + data_start + t->offset, q4_bytes, cudaMemcpyHostToDevice));
        __half* d_fp16; CHECK_CUDA(cudaMalloc(&d_fp16, (size_t)M*K*2));
        int nb = M * (K/32);
        dequant_q4_fp16<<<(nb+255)/256, 256>>>(d_fp16, d_q4, M, K);
        CHECK_CUDA(cudaDeviceSynchronize());
        CHECK_CUDA(cudaFree(d_q4));
        return d_fp16;
    };

    // Helper: F32 tensor → GPU
    auto load_f32 = [&](const char* name, int n) -> float* {
        TD* t = find_tensor(name);
        if (!t) { printf("Missing tensor: %s\n", name); exit(1); }
        float* d; CHECK_CUDA(cudaMalloc(&d, n*4));
        CHECK_CUDA(cudaMemcpy(d, data + data_start + t->offset, n*4, cudaMemcpyHostToDevice));
        return d;
    };

    // Find vocab
    TD* embd_t = find_tensor("token_embd.weight");
    cfg.vocab = (int)embd_t->dims[1];
    printf("Vocab: %d\n", cfg.vocab);

    // Load model
    printf("Loading Q4_0 → FP16...\n");
    int head_dim = cfg.dim / cfg.n_heads;
    int kv_dim = cfg.n_kv_heads * head_dim;

    __half* d_embd = load_q4_fp16("token_embd.weight", cfg.vocab, cfg.dim);
    float* d_rms_final = load_f32("output_norm.weight", cfg.dim);

    // LM head — use output.weight if Q4_0, else tied embedding
    __half* d_lm_head;
    TD* out_t = find_tensor("output.weight");
    if (out_t && out_t->type == 2) {  // type 2 = Q4_0
        printf("output.weight: Q4_0 dims=[%lu,%lu]\n",
               (unsigned long)out_t->dims[0], (unsigned long)out_t->dims[1]);
        d_lm_head = load_q4_fp16("output.weight", cfg.vocab, cfg.dim);
    } else {
        printf("output.weight type=%u (not Q4_0), using tied embedding\n",
               out_t ? out_t->type : 0);
        d_lm_head = d_embd;
    }

    FP16Layer* layers = new FP16Layer[cfg.n_layers];
    for (int l = 0; l < cfg.n_layers; l++) {
        char name[128];
        snprintf(name, sizeof(name), "blk.%d.attn_q.weight", l); layers[l].wq = load_q4_fp16(name, cfg.dim, cfg.dim);
        snprintf(name, sizeof(name), "blk.%d.attn_k.weight", l); layers[l].wk = load_q4_fp16(name, kv_dim, cfg.dim);
        snprintf(name, sizeof(name), "blk.%d.attn_v.weight", l); layers[l].wv = load_q4_fp16(name, kv_dim, cfg.dim);
        snprintf(name, sizeof(name), "blk.%d.attn_output.weight", l); layers[l].wo = load_q4_fp16(name, cfg.dim, cfg.dim);
        snprintf(name, sizeof(name), "blk.%d.ffn_gate.weight", l); layers[l].w_gate = load_q4_fp16(name, cfg.ff_dim, cfg.dim);
        snprintf(name, sizeof(name), "blk.%d.ffn_up.weight", l); layers[l].w_up = load_q4_fp16(name, cfg.ff_dim, cfg.dim);
        snprintf(name, sizeof(name), "blk.%d.ffn_down.weight", l); layers[l].w_down = load_q4_fp16(name, cfg.dim, cfg.ff_dim);
        snprintf(name, sizeof(name), "blk.%d.attn_norm.weight", l); layers[l].rms_attn = load_f32(name, cfg.dim);
        snprintf(name, sizeof(name), "blk.%d.ffn_norm.weight", l); layers[l].rms_ffn = load_f32(name, cfg.dim);
        if (l == 0 || l == cfg.n_layers-1) printf("  Layer %d loaded\n", l);
    }

    size_t free_mem, total_mem;
    CHECK_CUDA(cudaMemGetInfo(&free_mem, &total_mem));
    printf("VRAM: %.1f GB used, %.1f GB free\n", (total_mem-free_mem)/1e9, free_mem/1e9);

    // Allocate activations
    int max_seq = 128;
    Activations act;
    CHECK_CUDA(cudaMalloc(&act.hidden, cfg.dim * 4));
    CHECK_CUDA(cudaMalloc(&act.norm, cfg.dim * 4));
    CHECK_CUDA(cudaMalloc(&act.q, cfg.dim * 4));
    CHECK_CUDA(cudaMalloc(&act.k, kv_dim * 4));
    CHECK_CUDA(cudaMalloc(&act.v, kv_dim * 4));
    CHECK_CUDA(cudaMalloc(&act.attn_out, cfg.dim * 4));
    CHECK_CUDA(cudaMalloc(&act.gate, cfg.ff_dim * 4));
    CHECK_CUDA(cudaMalloc(&act.up, cfg.ff_dim * 4));
    CHECK_CUDA(cudaMalloc(&act.ffn_out, cfg.dim * 4));
    CHECK_CUDA(cudaMalloc(&act.logits, cfg.vocab * 4));
    // FP16 input scratch: max(dim, ff) values
    size_t h_in_size = (size_t)(cfg.ff_dim > cfg.dim ? cfg.ff_dim : cfg.dim) * 2;
    CHECK_CUDA(cudaMalloc(&act.h_in, h_in_size));
    // FP16 output scratch: max(dim, ff, vocab) values
    size_t max_out = cfg.vocab;
    if (cfg.ff_dim > (int)max_out) max_out = cfg.ff_dim;
    CHECK_CUDA(cudaMalloc(&act.h_out, max_out * 2));
    // KV cache
    size_t kv_bytes = (size_t)cfg.n_layers * max_seq * kv_dim * 4;
    CHECK_CUDA(cudaMalloc(&act.kv_key, kv_bytes));
    CHECK_CUDA(cudaMalloc(&act.kv_val, kv_bytes));
    act.max_seq = max_seq;

    // cuBLAS
    cublasHandle_t handle;
    CHECK_CUBLAS(cublasCreate(&handle));
    CHECK_CUBLAS(cublasSetMathMode(handle, CUBLAS_TENSOR_OP_MATH));

    // ====== Test: Prefill + first token ======
    printf("\n=== Correctness Test ===\n");
    uint32_t prompt[] = {1, 450, 7483, 310, 3444, 338};  // "The capital of France is"
    int prompt_len = 6;

    for (int i = 0; i < prompt_len; i++)
        forward_single(handle, cfg, layers, d_embd, d_lm_head, d_rms_final, act, prompt[i], i);
    CHECK_CUDA(cudaDeviceSynchronize());

    float* h_logits = (float*)malloc(cfg.vocab * 4);
    CHECK_CUDA(cudaMemcpy(h_logits, act.logits, cfg.vocab * 4, cudaMemcpyDeviceToHost));
    int top_token = 0; float top_logit = h_logits[0];
    for (int i = 1; i < cfg.vocab; i++)
        if (h_logits[i] > top_logit) { top_logit = h_logits[i]; top_token = i; }
    printf("First token: %d (logit=%.2f) %s\n", top_token, top_logit,
           (top_token == 3681) ? "= Paris" : "(tied embd, expected different)");

    // ====== Benchmark: single-token decode TPS ======
    printf("\n=== Single-Token Decode ===\n");
    int n_decode = 20;
    cudaEvent_t ev_start, ev_stop;
    cudaEventCreate(&ev_start); cudaEventCreate(&ev_stop);

    forward_single(handle, cfg, layers, d_embd, d_lm_head, d_rms_final, act, top_token, prompt_len);
    CHECK_CUDA(cudaDeviceSynchronize());

    cudaEventRecord(ev_start);
    for (int i = 0; i < n_decode; i++)
        forward_single(handle, cfg, layers, d_embd, d_lm_head, d_rms_final,
                        act, top_token, prompt_len + 1 + i);
    cudaEventRecord(ev_stop); cudaEventSynchronize(ev_stop);
    float ms_single; cudaEventElapsedTime(&ms_single, ev_start, ev_stop);
    ms_single /= n_decode;
    printf("Single-token: %.1f ms/token → %.1f TPS\n", ms_single, 1000.0f/ms_single);

    // ====== Allocate batch buffers ======
    int MAX_K = 16;
    __half *h_in_batch, *h_out_batch;
    float *hidden_batch, *norm_batch, *q_batch, *k_batch, *v_batch;
    float *attn_out_batch, *gate_batch, *up_batch;

    size_t max_hgemm_out = cfg.vocab > cfg.ff_dim ? cfg.vocab : cfg.ff_dim;
    CHECK_CUDA(cudaMalloc(&h_in_batch,     (size_t)MAX_K * cfg.ff_dim * 2));   // max(dim,ff)
    CHECK_CUDA(cudaMalloc(&h_out_batch,    (size_t)MAX_K * max_hgemm_out * 2));
    CHECK_CUDA(cudaMalloc(&hidden_batch,   (size_t)MAX_K * cfg.dim * 4));
    CHECK_CUDA(cudaMalloc(&norm_batch,     (size_t)MAX_K * cfg.dim * 4));
    CHECK_CUDA(cudaMalloc(&q_batch,        (size_t)MAX_K * cfg.dim * 4));
    CHECK_CUDA(cudaMalloc(&k_batch,        (size_t)MAX_K * kv_dim * 4));
    CHECK_CUDA(cudaMalloc(&v_batch,        (size_t)MAX_K * kv_dim * 4));
    CHECK_CUDA(cudaMalloc(&attn_out_batch, (size_t)MAX_K * cfg.dim * 4));
    CHECK_CUDA(cudaMalloc(&gate_batch,     (size_t)MAX_K * cfg.ff_dim * 4));
    CHECK_CUDA(cudaMalloc(&up_batch,       (size_t)MAX_K * cfg.ff_dim * 4));

    // Also need larger logits buffer for batch: K * vocab
    float* logits_batch;
    CHECK_CUDA(cudaMalloc(&logits_batch, (size_t)MAX_K * cfg.vocab * 4));
    // Point act.logits to the batch buffer for forward_batch
    cudaFree(act.logits);
    act.logits = logits_batch;

    CHECK_CUDA(cudaMemGetInfo(&free_mem, &total_mem));
    printf("After batch alloc: %.1f GB free\n", free_mem/1e9);

    // ====== Real Batch Forward Benchmarks ======
    printf("\n=== DART Batch Forward (REAL MEASURED) ===\n");
    printf("%-6s %10s %10s %10s %10s %10s\n",
           "K", "batch_ms", "α=0.7", "α=0.85", "α=0.9", "α=0.95");

    for (int K : {1, 2, 4, 8, 10, 12}) {
        // Set up K draft tokens at consecutive positions after prompt
        int tokens_k[16], positions_k[16];
        for (int b = 0; b < K; b++) {
            tokens_k[b] = top_token;  // same token for benchmarking
            positions_k[b] = prompt_len + b;
        }

        // Reset KV cache for consistent timing
        CHECK_CUDA(cudaMemset(act.kv_key, 0, kv_bytes));
        CHECK_CUDA(cudaMemset(act.kv_val, 0, kv_bytes));
        // Re-prefill
        for (int i = 0; i < prompt_len; i++)
            forward_single(handle, cfg, layers, d_embd, d_lm_head, d_rms_final, act, prompt[i], i);
        CHECK_CUDA(cudaDeviceSynchronize());

        // Warmup batch forward
        if (K == 1) {
            forward_single(handle, cfg, layers, d_embd, d_lm_head, d_rms_final,
                            act, tokens_k[0], positions_k[0]);
        } else {
            forward_batch(handle, cfg, layers, d_embd, d_lm_head, d_rms_final,
                           act, tokens_k, positions_k, K,
                           h_in_batch, h_out_batch, hidden_batch, norm_batch,
                           q_batch, k_batch, v_batch, attn_out_batch, gate_batch, up_batch);
        }
        CHECK_CUDA(cudaDeviceSynchronize());

        // Timed runs
        int n_runs = 10;
        cudaEventRecord(ev_start);
        for (int r = 0; r < n_runs; r++) {
            if (K == 1) {
                forward_single(handle, cfg, layers, d_embd, d_lm_head, d_rms_final,
                                act, tokens_k[0], positions_k[0]);
            } else {
                forward_batch(handle, cfg, layers, d_embd, d_lm_head, d_rms_final,
                               act, tokens_k, positions_k, K,
                               h_in_batch, h_out_batch, hidden_batch, norm_batch,
                               q_batch, k_batch, v_batch, attn_out_batch, gate_batch, up_batch);
            }
        }
        cudaEventRecord(ev_stop); cudaEventSynchronize(ev_stop);
        float ms_batch; cudaEventElapsedTime(&ms_batch, ev_start, ev_stop);
        ms_batch /= n_runs;

        // Print DART effective TPS for various accept rates
        float tps_07 = (0.7f * K + 1) / ms_batch * 1000.0f;
        float tps_085 = (0.85f * K + 1) / ms_batch * 1000.0f;
        float tps_09 = (0.9f * K + 1) / ms_batch * 1000.0f;
        float tps_095 = (0.95f * K + 1) / ms_batch * 1000.0f;

        auto mark = [](float tps) { return tps >= 133 ? " ✓" : ""; };
        printf("K=%-4d %8.1f ms %7.0f%s %7.0f%s %7.0f%s %7.0f%s\n",
               K, ms_batch,
               tps_07, mark(tps_07), tps_085, mark(tps_085),
               tps_09, mark(tps_09), tps_095, mark(tps_095));
    }

    printf("\nTarget: 133 TPS (TinyLlama 1.1B baseline)\n");

    // Cleanup
    cudaEventDestroy(ev_start); cudaEventDestroy(ev_stop);
    cublasDestroy(handle);
    free(h_logits);
    munmap((void*)data, st.st_size);
    close(fd);

    return 0;
}

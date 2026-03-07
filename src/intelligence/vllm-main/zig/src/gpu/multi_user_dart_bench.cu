// Multi-User DART Batch Benchmark: Weight-sharing HGEMM + FP16 KV Cache
//
// Proves that B users can share FP16 HGEMM for weight projections while
// maintaining separate FP16 KV caches. HGEMM is BW-limited (~58ms on T4)
// and insensitive to token count, so B×K tokens cost ≈ same as K tokens.
//
// Key optimizations over single-user fp16_e2e_bench.cu:
//   1. FP16 KV cache — halves attention read bandwidth
//   2. Weight-sharing HGEMM — one call for all B×K tokens
//   3. Fused FP16 SwiGLU — eliminates 3 conversion launches per layer
//
// Compile: nvcc -O3 -arch=sm_75 -lcublas -o multi_user_dart_bench multi_user_dart_bench.cu
// Run:     ./multi_user_dart_bench /path/to/llama-2-7b-chat.Q4_0.gguf

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
// GPU Kernels
// ============================================================================

__global__ void rms_norm_kernel(float* __restrict__ out,
                                 const float* __restrict__ x,
                                 const float* __restrict__ weight,
                                 int dim, float eps) {
    extern __shared__ float smem[];
    int tid = threadIdx.x;
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
    for (int i = tid; i < dim; i += blockDim.x)
        out[i] = x[i] * rms * weight[i];
}

__global__ void embedding_kernel(float* __restrict__ out,
                                  const __half* __restrict__ table,
                                  int token_id, int dim) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < dim) out[i] = __half2float(table[token_id * dim + i]);
}

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
    float cos_t = cosf(theta), sin_t = sinf(theta);
    int idx0 = head * head_dim + j;
    int idx1 = head * head_dim + j + head_dim / 2;
    float v0 = vec[idx0], v1 = vec[idx1];
    vec[idx0] = v0 * cos_t - v1 * sin_t;
    vec[idx1] = v0 * sin_t + v1 * cos_t;
}

__global__ void swiglu_kernel(float* __restrict__ gate,
                               const float* __restrict__ up, int dim) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < dim) {
        float g = gate[i];
        gate[i] = (g / (1.0f + expf(-g))) * up[i];
    }
}

// Fused FP16 SwiGLU: gate[i] = silu(gate[i]) * up[i], all FP16
// Loads FP16, computes in FP32, stores FP16. Eliminates 3 conversion launches.
__global__ void fp16_swiglu_kernel(__half* __restrict__ gate,
                                    const __half* __restrict__ up, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) {
        float g = __half2float(gate[i]);
        float u = __half2float(up[i]);
        float silu = g / (1.0f + expf(-g));
        gate[i] = __float2half(silu * u);
    }
}

__global__ void vecadd_kernel(float* __restrict__ out,
                               const float* __restrict__ a,
                               const float* __restrict__ b, int dim) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < dim) out[i] = a[i] + b[i];
}

__global__ void fp32_to_fp16_kernel(__half* __restrict__ out,
                                     const float* __restrict__ in, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) out[i] = __float2half(in[i]);
}

__global__ void fp16_to_fp32_kernel(float* __restrict__ out,
                                     const __half* __restrict__ in, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) out[i] = __half2float(in[i]);
}

// FP32 KV cache attention (original, for reference/comparison)
__global__ void decode_attention_f32kv(
    float* __restrict__ out, const float* __restrict__ q,
    const float* __restrict__ k_cache, const float* __restrict__ v_cache,
    int n_heads, int n_kv_heads, int head_dim, int seq_len, float scale,
    int max_seq_len)
{
    int h = blockIdx.x;
    if (h >= n_heads) return;
    int kv_h = h / (n_heads / n_kv_heads);
    extern __shared__ float smem[];
    int tid = threadIdx.x;

    const float* q_head = q + h * head_dim;
    for (int s = tid; s < seq_len; s += blockDim.x) {
        const float* k_s = k_cache + s * n_kv_heads * head_dim + kv_h * head_dim;
        float dot = 0.0f;
        for (int d = 0; d < head_dim; d++) dot += q_head[d] * k_s[d];
        smem[s] = dot * scale;
    }
    __syncthreads();

    // Softmax
    float max_val = -1e30f;
    for (int s = tid; s < seq_len; s += blockDim.x) max_val = fmaxf(max_val, smem[s]);
    for (int off = 16; off >= 1; off >>= 1) max_val = fmaxf(max_val, __shfl_xor_sync(0xFFFFFFFF, max_val, off));
    __shared__ float bmax[32]; int wid = tid/32, lane = tid%32;
    if (lane == 0) bmax[wid] = max_val; __syncthreads();
    if (tid < 32) { max_val = (tid < blockDim.x/32) ? bmax[tid] : -1e30f;
        for (int off = 16; off >= 1; off >>= 1) max_val = fmaxf(max_val, __shfl_xor_sync(0xFFFFFFFF, max_val, off)); }
    __syncthreads(); if (tid == 0) bmax[0] = max_val; __syncthreads(); max_val = bmax[0];

    float sum_exp = 0.0f;
    for (int s = tid; s < seq_len; s += blockDim.x) { smem[s] = expf(smem[s] - max_val); sum_exp += smem[s]; }
    __shared__ float bsum[32];
    for (int off = 16; off >= 1; off >>= 1) sum_exp += __shfl_xor_sync(0xFFFFFFFF, sum_exp, off);
    if (lane == 0) bsum[wid] = sum_exp; __syncthreads();
    if (tid < 32) { sum_exp = (tid < blockDim.x/32) ? bsum[tid] : 0.0f;
        for (int off = 16; off >= 1; off >>= 1) sum_exp += __shfl_xor_sync(0xFFFFFFFF, sum_exp, off); }
    __syncthreads(); if (tid == 0) bsum[0] = sum_exp; __syncthreads();
    float inv_sum = 1.0f / bsum[0];
    for (int s = tid; s < seq_len; s += blockDim.x) smem[s] *= inv_sum;
    __syncthreads();

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

// FP16 KV cache attention — loads K,V as __half, computes in FP32
// Halves memory bandwidth for attention reads vs FP32 KV.
__global__ void decode_attention_fp16kv(
    float* __restrict__ out, const float* __restrict__ q,
    const __half* __restrict__ k_cache, const __half* __restrict__ v_cache,
    int n_heads, int n_kv_heads, int head_dim, int seq_len, float scale,
    int max_seq_len)
{
    int h = blockIdx.x;
    if (h >= n_heads) return;
    int kv_h = h / (n_heads / n_kv_heads);
    extern __shared__ float smem[];
    int tid = threadIdx.x;

    // Q @ K^T — load K as FP16, convert on the fly
    const float* q_head = q + h * head_dim;
    for (int s = tid; s < seq_len; s += blockDim.x) {
        const __half* k_s = k_cache + s * n_kv_heads * head_dim + kv_h * head_dim;
        float dot = 0.0f;
        for (int d = 0; d < head_dim; d++)
            dot += q_head[d] * __half2float(k_s[d]);
        smem[s] = dot * scale;
    }
    __syncthreads();

    // Softmax (same as FP32 version — all in FP32 for stability)
    float max_val = -1e30f;
    for (int s = tid; s < seq_len; s += blockDim.x) max_val = fmaxf(max_val, smem[s]);
    for (int off = 16; off >= 1; off >>= 1) max_val = fmaxf(max_val, __shfl_xor_sync(0xFFFFFFFF, max_val, off));
    __shared__ float bmax[32]; int wid = tid/32, lane = tid%32;
    if (lane == 0) bmax[wid] = max_val; __syncthreads();
    if (tid < 32) { max_val = (tid < blockDim.x/32) ? bmax[tid] : -1e30f;
        for (int off = 16; off >= 1; off >>= 1) max_val = fmaxf(max_val, __shfl_xor_sync(0xFFFFFFFF, max_val, off)); }
    __syncthreads(); if (tid == 0) bmax[0] = max_val; __syncthreads(); max_val = bmax[0];

    float sum_exp = 0.0f;
    for (int s = tid; s < seq_len; s += blockDim.x) { smem[s] = expf(smem[s] - max_val); sum_exp += smem[s]; }
    __shared__ float bsum[32];
    for (int off = 16; off >= 1; off >>= 1) sum_exp += __shfl_xor_sync(0xFFFFFFFF, sum_exp, off);
    if (lane == 0) bsum[wid] = sum_exp; __syncthreads();
    if (tid < 32) { sum_exp = (tid < blockDim.x/32) ? bsum[tid] : 0.0f;
        for (int off = 16; off >= 1; off >>= 1) sum_exp += __shfl_xor_sync(0xFFFFFFFF, sum_exp, off); }
    __syncthreads(); if (tid == 0) bsum[0] = sum_exp; __syncthreads();
    float inv_sum = 1.0f / bsum[0];
    for (int s = tid; s < seq_len; s += blockDim.x) smem[s] *= inv_sum;
    __syncthreads();

    // Weighted V sum — load V as FP16, convert on the fly
    float* out_head = out + h * head_dim;
    for (int d = tid; d < head_dim; d += blockDim.x) {
        float acc = 0.0f;
        for (int s = 0; s < seq_len; s++) {
            const __half* v_s = v_cache + s * n_kv_heads * head_dim + kv_h * head_dim;
            acc += smem[s] * __half2float(v_s[d]);
        }
        out_head[d] = acc;
    }
}

// Store K,V as FP16 into cache (converts FP32 activation → FP16 cache)
__global__ void store_kv_fp16(__half* __restrict__ dst,
                               const float* __restrict__ src, int kv_dim) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < kv_dim) dst[i] = __float2half(src[i]);
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
// GGUF Parser
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
    float *rms_attn, *rms_ffn;
};

// Per-user FP16 KV cache
struct FP16KVCache {
    __half* key;   // [n_layers * max_seq * kv_dim] as FP16
    __half* val;   // [n_layers * max_seq * kv_dim] as FP16
    int max_seq;
    int kv_dim;
    int n_layers;
    int seq_len;   // current sequence length for this user
};

void init_fp16_kv(FP16KVCache& kv, int n_layers, int max_seq, int kv_dim) {
    kv.n_layers = n_layers; kv.max_seq = max_seq; kv.kv_dim = kv_dim; kv.seq_len = 0;
    size_t bytes = (size_t)n_layers * max_seq * kv_dim * sizeof(__half);
    CHECK_CUDA(cudaMalloc(&kv.key, bytes));
    CHECK_CUDA(cudaMalloc(&kv.val, bytes));
    CHECK_CUDA(cudaMemset(kv.key, 0, bytes));
    CHECK_CUDA(cudaMemset(kv.val, 0, bytes));
}

void free_fp16_kv(FP16KVCache& kv) {
    cudaFree(kv.key); cudaFree(kv.val);
}

__half* kv_key_ptr(FP16KVCache& kv, int layer, int pos) {
    return kv.key + (long long)layer * kv.max_seq * kv.kv_dim + pos * kv.kv_dim;
}
__half* kv_val_ptr(FP16KVCache& kv, int layer, int pos) {
    return kv.val + (long long)layer * kv.max_seq * kv.kv_dim + pos * kv.kv_dim;
}
__half* kv_key_layer(FP16KVCache& kv, int layer) {
    return kv.key + (long long)layer * kv.max_seq * kv.kv_dim;
}
__half* kv_val_layer(FP16KVCache& kv, int layer) {
    return kv.val + (long long)layer * kv.max_seq * kv.kv_dim;
}

// ============================================================================
// Single-token forward (for prefill) — uses FP16 KV cache
// ============================================================================
void forward_single_fp16kv(cublasHandle_t handle, Config& cfg, FP16Layer* layers,
                            __half* d_embd, __half* d_lm_head, float* d_rms_final,
                            float* hidden, float* norm, float* q, float* k, float* v,
                            float* attn_out, float* gate, float* up, float* ffn_out,
                            float* logits, __half* h_in, __half* h_out,
                            FP16KVCache& kv, int token, int pos) {
    int dim = cfg.dim, ff = cfg.ff_dim;
    int n_heads = cfg.n_heads, n_kv_heads = cfg.n_kv_heads;
    int head_dim = dim / n_heads;
    int kv_dim = n_kv_heads * head_dim;
    int seq_len = pos + 1;
    __half alpha_h = __float2half(1.0f), beta_h = __float2half(0.0f);

    embedding_kernel<<<(dim+255)/256, 256>>>(hidden, d_embd, token, dim);

    for (int l = 0; l < cfg.n_layers; l++) {
        FP16Layer& lw = layers[l];
        rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(norm, hidden, lw.rms_attn, dim, 1e-5f);
        fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(h_in, norm, dim);

        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, 1, dim, &alpha_h, lw.wq, dim, h_in, dim, &beta_h, h_out, dim);
        fp16_to_fp32_kernel<<<(dim+255)/256, 256>>>(q, h_out, dim);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, kv_dim, 1, dim, &alpha_h, lw.wk, dim, h_in, dim, &beta_h, h_out, kv_dim);
        fp16_to_fp32_kernel<<<(kv_dim+255)/256, 256>>>(k, h_out, kv_dim);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, kv_dim, 1, dim, &alpha_h, lw.wv, dim, h_in, dim, &beta_h, h_out, kv_dim);
        fp16_to_fp32_kernel<<<(kv_dim+255)/256, 256>>>(v, h_out, kv_dim);

        rope_kernel<<<(dim+255)/256, 256>>>(q, pos, head_dim, cfg.rope_base, n_heads);
        rope_kernel<<<(kv_dim+255)/256, 256>>>(k, pos, head_dim, cfg.rope_base, n_kv_heads);

        // Store K,V as FP16 into per-user cache
        store_kv_fp16<<<(kv_dim+255)/256, 256>>>(kv_key_ptr(kv, l, pos), k, kv_dim);
        store_kv_fp16<<<(kv_dim+255)/256, 256>>>(kv_val_ptr(kv, l, pos), v, kv_dim);

        float scale = 1.0f / sqrtf((float)head_dim);
        int smem_attn = seq_len * sizeof(float);
        if (smem_attn < 48*1024)
            decode_attention_fp16kv<<<n_heads, 256, smem_attn>>>(
                attn_out, q, kv_key_layer(kv, l), kv_val_layer(kv, l),
                n_heads, n_kv_heads, head_dim, seq_len, scale, kv.max_seq);

        fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(h_in, attn_out, dim);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, 1, dim, &alpha_h, lw.wo, dim, h_in, dim, &beta_h, h_out, dim);
        fp16_to_fp32_kernel<<<(dim+255)/256, 256>>>(norm, h_out, dim);
        vecadd_kernel<<<(dim+255)/256, 256>>>(hidden, hidden, norm, dim);

        rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(norm, hidden, lw.rms_ffn, dim, 1e-5f);
        fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(h_in, norm, dim);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, ff, 1, dim, &alpha_h, lw.w_gate, dim, h_in, dim, &beta_h, h_out, ff);
        fp16_to_fp32_kernel<<<(ff+255)/256, 256>>>(gate, h_out, ff);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, ff, 1, dim, &alpha_h, lw.w_up, dim, h_in, dim, &beta_h, h_out, ff);
        fp16_to_fp32_kernel<<<(ff+255)/256, 256>>>(up, h_out, ff);
        swiglu_kernel<<<(ff+255)/256, 256>>>(gate, up, ff);
        fp32_to_fp16_kernel<<<(ff+255)/256, 256>>>(h_in, gate, ff);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, 1, ff, &alpha_h, lw.w_down, ff, h_in, ff, &beta_h, h_out, dim);
        fp16_to_fp32_kernel<<<(dim+255)/256, 256>>>(ffn_out, h_out, dim);
        vecadd_kernel<<<(dim+255)/256, 256>>>(hidden, hidden, ffn_out, dim);
    }

    rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(norm, hidden, d_rms_final, dim, 1e-5f);
    fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(h_in, norm, dim);
    cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, cfg.vocab, 1, dim, &alpha_h, d_lm_head, dim, h_in, dim, &beta_h, h_out, cfg.vocab);
    fp16_to_fp32_kernel<<<(cfg.vocab+255)/256, 256>>>(logits, h_out, cfg.vocab);
    kv.seq_len = pos + 1;
}

// ============================================================================
// Multi-User Batch Forward — B users × K tokens, FP16 KV, shared HGEMM
// ============================================================================
// All B×K tokens share weight projections via single HGEMM calls.
// Per-token ops (RMSNorm, RoPE, attention) dispatch to correct user's KV cache.
//
// Layout: tokens are ordered [user0_tok0, user0_tok1, ..., user1_tok0, ...]
// user_ids[t] = which user token t belongs to
// positions[t] = position of token t in its user's context
void forward_multi_user(
    cublasHandle_t handle, Config& cfg, FP16Layer* layers,
    __half* d_embd, __half* d_lm_head, float* d_rms_final,
    FP16KVCache* kv_caches, int B, int K,
    int* tokens, int* positions, int* user_ids,
    // Batch scratch buffers [T × dim/kv_dim/ff]
    __half* h_in_batch, __half* h_out_batch,
    float* hidden_batch, float* norm_batch,
    float* q_batch, float* k_batch, float* v_batch,
    float* attn_out_batch, float* gate_batch, float* up_batch,
    // FP16 scratch for fused SwiGLU path
    __half* h_gate_fp16, __half* h_up_fp16)
{
    int T = B * K;  // total tokens
    int dim = cfg.dim, ff = cfg.ff_dim;
    int n_heads = cfg.n_heads, n_kv_heads = cfg.n_kv_heads;
    int head_dim = dim / n_heads;
    int kv_dim = n_kv_heads * head_dim;
    __half alpha_h = __float2half(1.0f), beta_h = __float2half(0.0f);

    // 1. Embedding lookup for all T tokens
    for (int t = 0; t < T; t++)
        embedding_kernel<<<(dim+255)/256, 256>>>(hidden_batch + t*dim, d_embd, tokens[t], dim);

    // 2. Transformer layers
    for (int l = 0; l < cfg.n_layers; l++) {
        FP16Layer& lw = layers[l];

        // RMSNorm for all T tokens
        for (int t = 0; t < T; t++)
            rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(
                norm_batch + t*dim, hidden_batch + t*dim, lw.rms_attn, dim, 1e-5f);

        // Shared HGEMM: all T tokens in one call
        fp32_to_fp16_kernel<<<(T*dim+255)/256, 256>>>(h_in_batch, norm_batch, T*dim);

        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, T, dim,
                     &alpha_h, lw.wq, dim, h_in_batch, dim, &beta_h, h_out_batch, dim);
        fp16_to_fp32_kernel<<<(T*dim+255)/256, 256>>>(q_batch, h_out_batch, T*dim);

        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, kv_dim, T, dim,
                     &alpha_h, lw.wk, dim, h_in_batch, dim, &beta_h, h_out_batch, kv_dim);
        fp16_to_fp32_kernel<<<(T*kv_dim+255)/256, 256>>>(k_batch, h_out_batch, T*kv_dim);

        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, kv_dim, T, dim,
                     &alpha_h, lw.wv, dim, h_in_batch, dim, &beta_h, h_out_batch, kv_dim);
        fp16_to_fp32_kernel<<<(T*kv_dim+255)/256, 256>>>(v_batch, h_out_batch, T*kv_dim);

        // Per-token: RoPE + KV store (FP16) + Attention (FP16 KV)
        for (int t = 0; t < T; t++) {
            int u = user_ids[t];
            int pos = positions[t];
            int seq = pos + 1;

            rope_kernel<<<(dim+255)/256, 256>>>(q_batch + t*dim, pos, head_dim, cfg.rope_base, n_heads);
            rope_kernel<<<(kv_dim+255)/256, 256>>>(k_batch + t*kv_dim, pos, head_dim, cfg.rope_base, n_kv_heads);

            // Store K,V as FP16 into user's KV cache
            store_kv_fp16<<<(kv_dim+255)/256, 256>>>(
                kv_key_ptr(kv_caches[u], l, pos), k_batch + t*kv_dim, kv_dim);
            store_kv_fp16<<<(kv_dim+255)/256, 256>>>(
                kv_val_ptr(kv_caches[u], l, pos), v_batch + t*kv_dim, kv_dim);

            float scale = 1.0f / sqrtf((float)head_dim);
            int smem_attn = seq * sizeof(float);
            if (smem_attn < 48*1024)
                decode_attention_fp16kv<<<n_heads, 256, smem_attn>>>(
                    attn_out_batch + t*dim, q_batch + t*dim,
                    kv_key_layer(kv_caches[u], l), kv_val_layer(kv_caches[u], l),
                    n_heads, n_kv_heads, head_dim, seq, scale, kv_caches[u].max_seq);
        }

        // Shared HGEMM: O projection
        fp32_to_fp16_kernel<<<(T*dim+255)/256, 256>>>(h_in_batch, attn_out_batch, T*dim);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, T, dim,
                     &alpha_h, lw.wo, dim, h_in_batch, dim, &beta_h, h_out_batch, dim);
        fp16_to_fp32_kernel<<<(T*dim+255)/256, 256>>>(norm_batch, h_out_batch, T*dim);

        // Residual
        vecadd_kernel<<<(T*dim+255)/256, 256>>>(hidden_batch, hidden_batch, norm_batch, T*dim);

        // FFN RMSNorm
        for (int t = 0; t < T; t++)
            rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(
                norm_batch + t*dim, hidden_batch + t*dim, lw.rms_ffn, dim, 1e-5f);

        // Shared HGEMM: FFN with fused FP16 SwiGLU
        fp32_to_fp16_kernel<<<(T*dim+255)/256, 256>>>(h_in_batch, norm_batch, T*dim);

        // Gate → h_gate_fp16 (stays FP16)
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, ff, T, dim,
                     &alpha_h, lw.w_gate, dim, h_in_batch, dim, &beta_h, h_gate_fp16, ff);
        // Up → h_up_fp16 (stays FP16)
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, ff, T, dim,
                     &alpha_h, lw.w_up, dim, h_in_batch, dim, &beta_h, h_up_fp16, ff);

        // Fused FP16 SwiGLU: gate = silu(gate) * up, all FP16
        fp16_swiglu_kernel<<<(T*ff+255)/256, 256>>>(h_gate_fp16, h_up_fp16, T*ff);

        // Down projection: FP16 input directly from SwiGLU
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, T, ff,
                     &alpha_h, lw.w_down, ff, h_gate_fp16, ff, &beta_h, h_out_batch, dim);
        fp16_to_fp32_kernel<<<(T*dim+255)/256, 256>>>(norm_batch, h_out_batch, T*dim);

        // Residual
        vecadd_kernel<<<(T*dim+255)/256, 256>>>(hidden_batch, hidden_batch, norm_batch, T*dim);
    }

    // 3. Final RMSNorm + LM head
    for (int t = 0; t < T; t++)
        rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(
            norm_batch + t*dim, hidden_batch + t*dim, d_rms_final, dim, 1e-5f);

    fp32_to_fp16_kernel<<<(T*dim+255)/256, 256>>>(h_in_batch, norm_batch, T*dim);
    cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, cfg.vocab, T, dim,
                 &alpha_h, d_lm_head, dim, h_in_batch, dim, &beta_h, h_out_batch, cfg.vocab);
    // Logits stay as FP16 in h_out_batch — caller converts per-user as needed
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

    uint64_t n_tensors = read_u64(data + 8);
    uint64_t n_kv = read_u64(data + 16);
    size_t kv_start = 24;

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

    struct TD { char name[128]; int name_len; uint64_t dims[4]; uint32_t n_dims, type; uint64_t offset; };
    TD* tensors = new TD[n_tensors];
    for (uint64_t i = 0; i < n_tensors; i++) {
        TD& t = tensors[i];
        t.name_len = (int)read_u64(data + pos); memcpy(t.name, data + pos + 8, t.name_len); t.name[t.name_len] = 0;
        pos += 8 + t.name_len;
        t.n_dims = read_u32(data + pos); pos += 4;
        for (uint32_t d = 0; d < t.n_dims; d++) { t.dims[d] = read_u64(data + pos); pos += 8; }
        for (uint32_t d = t.n_dims; d < 4; d++) t.dims[d] = 1;
        t.type = read_u32(data + pos); pos += 4;
        t.offset = read_u64(data + pos); pos += 8;
    }
    size_t data_start = (pos + 31) & ~31ULL;

    auto find_tensor = [&](const char* name) -> TD* {
        for (uint64_t i = 0; i < n_tensors; i++)
            if (strcmp(tensors[i].name, name) == 0) return &tensors[i];
        return nullptr;
    };
    auto load_q4_fp16 = [&](const char* name, int M, int K) -> __half* {
        TD* t = find_tensor(name);
        if (!t) { printf("Missing: %s\n", name); exit(1); }
        size_t q4_bytes = (size_t)M * (K/32) * 18;
        uint8_t* d_q4; CHECK_CUDA(cudaMalloc(&d_q4, q4_bytes));
        CHECK_CUDA(cudaMemcpy(d_q4, data + data_start + t->offset, q4_bytes, cudaMemcpyHostToDevice));
        __half* d_fp16; CHECK_CUDA(cudaMalloc(&d_fp16, (size_t)M*K*2));
        dequant_q4_fp16<<<(M*(K/32)+255)/256, 256>>>(d_fp16, d_q4, M, K);
        CHECK_CUDA(cudaDeviceSynchronize()); CHECK_CUDA(cudaFree(d_q4));
        return d_fp16;
    };
    auto load_f32 = [&](const char* name, int n) -> float* {
        TD* t = find_tensor(name);
        if (!t) { printf("Missing: %s\n", name); exit(1); }
        float* d; CHECK_CUDA(cudaMalloc(&d, n*4));
        CHECK_CUDA(cudaMemcpy(d, data + data_start + t->offset, n*4, cudaMemcpyHostToDevice));
        return d;
    };

    TD* embd_t = find_tensor("token_embd.weight");
    cfg.vocab = (int)embd_t->dims[1];
    printf("Vocab: %d\n", cfg.vocab);

    // Load model
    printf("Loading Q4_0 → FP16...\n");
    int head_dim = cfg.dim / cfg.n_heads;
    int kv_dim = cfg.n_kv_heads * head_dim;

    __half* d_embd = load_q4_fp16("token_embd.weight", cfg.vocab, cfg.dim);
    float* d_rms_final = load_f32("output_norm.weight", cfg.dim);

    __half* d_lm_head;
    TD* out_t = find_tensor("output.weight");
    if (out_t && out_t->type == 2) {
        d_lm_head = load_q4_fp16("output.weight", cfg.vocab, cfg.dim);
    } else {
        printf("output.weight type=%u, using tied embedding\n", out_t ? out_t->type : 0);
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
    printf("VRAM after weights: %.1f GB used, %.1f GB free\n", (total_mem-free_mem)/1e9, free_mem/1e9);

    // cuBLAS
    cublasHandle_t handle;
    CHECK_CUBLAS(cublasCreate(&handle));
    CHECK_CUBLAS(cublasSetMathMode(handle, CUBLAS_TENSOR_OP_MATH));

    // ========================================================================
    // Allocate per-user FP16 KV caches + single-token activation buffers
    // ========================================================================
    int MAX_USERS = 3;
    int max_seq = 128;
    FP16KVCache kv_caches[3];
    for (int u = 0; u < MAX_USERS; u++)
        init_fp16_kv(kv_caches[u], cfg.n_layers, max_seq, kv_dim);

    // Single-token activation buffers (for prefill)
    float *d_hidden, *d_norm, *d_q, *d_k, *d_v, *d_attn_out, *d_gate, *d_up, *d_ffn_out, *d_logits;
    __half *d_h_in, *d_h_out;
    CHECK_CUDA(cudaMalloc(&d_hidden, cfg.dim * 4));
    CHECK_CUDA(cudaMalloc(&d_norm, cfg.dim * 4));
    CHECK_CUDA(cudaMalloc(&d_q, cfg.dim * 4));
    CHECK_CUDA(cudaMalloc(&d_k, kv_dim * 4));
    CHECK_CUDA(cudaMalloc(&d_v, kv_dim * 4));
    CHECK_CUDA(cudaMalloc(&d_attn_out, cfg.dim * 4));
    CHECK_CUDA(cudaMalloc(&d_gate, cfg.ff_dim * 4));
    CHECK_CUDA(cudaMalloc(&d_up, cfg.ff_dim * 4));
    CHECK_CUDA(cudaMalloc(&d_ffn_out, cfg.dim * 4));
    CHECK_CUDA(cudaMalloc(&d_logits, cfg.vocab * 4));
    size_t max_h = (cfg.ff_dim > cfg.dim ? cfg.ff_dim : cfg.dim);
    size_t max_out = (cfg.vocab > (int)max_h ? cfg.vocab : max_h);
    CHECK_CUDA(cudaMalloc(&d_h_in, max_h * 2));
    CHECK_CUDA(cudaMalloc(&d_h_out, max_out * 2));

    // ========================================================================
    // Allocate batch buffers for multi-user DART
    // ========================================================================
    int MAX_T = MAX_USERS * 16;  // max total tokens = 3 users × 16 draft each
    __half *h_in_batch, *h_out_batch, *h_gate_fp16, *h_up_fp16;
    float *hidden_batch, *norm_batch, *q_batch, *k_batch, *v_batch;
    float *attn_out_batch, *gate_batch, *up_batch;

    CHECK_CUDA(cudaMalloc(&h_in_batch,     (size_t)MAX_T * cfg.ff_dim * 2));
    CHECK_CUDA(cudaMalloc(&h_out_batch,    (size_t)MAX_T * max_out * 2));
    CHECK_CUDA(cudaMalloc(&h_gate_fp16,    (size_t)MAX_T * cfg.ff_dim * 2));
    CHECK_CUDA(cudaMalloc(&h_up_fp16,      (size_t)MAX_T * cfg.ff_dim * 2));
    CHECK_CUDA(cudaMalloc(&hidden_batch,   (size_t)MAX_T * cfg.dim * 4));
    CHECK_CUDA(cudaMalloc(&norm_batch,     (size_t)MAX_T * cfg.dim * 4));
    CHECK_CUDA(cudaMalloc(&q_batch,        (size_t)MAX_T * cfg.dim * 4));
    CHECK_CUDA(cudaMalloc(&k_batch,        (size_t)MAX_T * kv_dim * 4));
    CHECK_CUDA(cudaMalloc(&v_batch,        (size_t)MAX_T * kv_dim * 4));
    CHECK_CUDA(cudaMalloc(&attn_out_batch, (size_t)MAX_T * cfg.dim * 4));
    CHECK_CUDA(cudaMalloc(&gate_batch,     (size_t)MAX_T * cfg.ff_dim * 4));
    CHECK_CUDA(cudaMalloc(&up_batch,       (size_t)MAX_T * cfg.ff_dim * 4));

    CHECK_CUDA(cudaMemGetInfo(&free_mem, &total_mem));
    printf("VRAM after alloc: %.1f GB used, %.1f GB free\n", (total_mem-free_mem)/1e9, free_mem/1e9);
    printf("FP16 KV per user: %.0f MB (ctx=%d)\n",
           (double)cfg.n_layers * max_seq * kv_dim * 2 * 2 / 1e6, max_seq);

    // ========================================================================
    // Prefill all users with the same prompt (for benchmarking)
    // ========================================================================
    uint32_t prompt[] = {1, 450, 7483, 310, 3444, 338};
    int prompt_len = 6;

    printf("\nPrefilling %d users with %d-token prompt...\n", MAX_USERS, prompt_len);
    for (int u = 0; u < MAX_USERS; u++) {
        for (int i = 0; i < prompt_len; i++)
            forward_single_fp16kv(handle, cfg, layers, d_embd, d_lm_head, d_rms_final,
                                   d_hidden, d_norm, d_q, d_k, d_v, d_attn_out,
                                   d_gate, d_up, d_ffn_out, d_logits, d_h_in, d_h_out,
                                   kv_caches[u], prompt[i], i);
        kv_caches[u].seq_len = prompt_len;
    }
    CHECK_CUDA(cudaDeviceSynchronize());

    // Get first token for benchmarking
    float* h_logits = (float*)malloc(cfg.vocab * 4);
    CHECK_CUDA(cudaMemcpy(h_logits, d_logits, cfg.vocab * 4, cudaMemcpyDeviceToHost));
    int top_token = 0; float top_logit = h_logits[0];
    for (int i = 1; i < cfg.vocab; i++)
        if (h_logits[i] > top_logit) { top_logit = h_logits[i]; top_token = i; }
    printf("Top token: %d (logit=%.2f)\n", top_token, top_logit);

    // ========================================================================
    // Benchmark: Single-user FP16 KV baseline
    // ========================================================================
    printf("\n=== Single-User FP16 KV Baseline ===\n");
    cudaEvent_t ev_start, ev_stop;
    cudaEventCreate(&ev_start); cudaEventCreate(&ev_stop);

    int n_runs = 10;
    cudaEventRecord(ev_start);
    for (int r = 0; r < n_runs; r++)
        forward_single_fp16kv(handle, cfg, layers, d_embd, d_lm_head, d_rms_final,
                               d_hidden, d_norm, d_q, d_k, d_v, d_attn_out,
                               d_gate, d_up, d_ffn_out, d_logits, d_h_in, d_h_out,
                               kv_caches[0], top_token, prompt_len);
    cudaEventRecord(ev_stop); cudaEventSynchronize(ev_stop);
    float ms_single; cudaEventElapsedTime(&ms_single, ev_start, ev_stop);
    ms_single /= n_runs;
    printf("Single-token (FP16 KV): %.1f ms → %.1f TPS\n", ms_single, 1000.0f/ms_single);

    // ========================================================================
    // Benchmark: Multi-user DART batch
    // ========================================================================
    printf("\n=== Multi-User DART Batch (Weight-Sharing HGEMM + FP16 KV + Fused SwiGLU) ===\n");
    printf("%-4s %-4s %6s %10s %10s %10s %10s %10s\n",
           "B", "K", "T", "batch_ms", "α=0.7", "α=0.85", "α=0.9", "agg_TPS");

    for (int B : {1, 2, 3}) {
        for (int K : {8, 10, 12, 14}) {
            int T = B * K;
            if (T > MAX_T) continue;

            // Build token/position/user arrays
            int tokens_arr[48], positions_arr[48], user_ids_arr[48];
            for (int u = 0; u < B; u++) {
                for (int k = 0; k < K; k++) {
                    int idx = u * K + k;
                    tokens_arr[idx] = top_token;
                    positions_arr[idx] = prompt_len + k;
                    user_ids_arr[idx] = u;
                }
            }

            // Reset KV caches for consistent timing
            for (int u = 0; u < B; u++) {
                size_t kv_bytes = (size_t)cfg.n_layers * max_seq * kv_dim * sizeof(__half);
                CHECK_CUDA(cudaMemset(kv_caches[u].key, 0, kv_bytes));
                CHECK_CUDA(cudaMemset(kv_caches[u].val, 0, kv_bytes));
                // Re-prefill
                for (int i = 0; i < prompt_len; i++)
                    forward_single_fp16kv(handle, cfg, layers, d_embd, d_lm_head, d_rms_final,
                                           d_hidden, d_norm, d_q, d_k, d_v, d_attn_out,
                                           d_gate, d_up, d_ffn_out, d_logits, d_h_in, d_h_out,
                                           kv_caches[u], prompt[i], i);
                kv_caches[u].seq_len = prompt_len;
            }
            CHECK_CUDA(cudaDeviceSynchronize());

            // Copy arrays to GPU
            int *d_tokens, *d_positions, *d_user_ids;
            CHECK_CUDA(cudaMalloc(&d_tokens, T*4));
            CHECK_CUDA(cudaMalloc(&d_positions, T*4));
            CHECK_CUDA(cudaMalloc(&d_user_ids, T*4));
            CHECK_CUDA(cudaMemcpy(d_tokens, tokens_arr, T*4, cudaMemcpyHostToDevice));
            CHECK_CUDA(cudaMemcpy(d_positions, positions_arr, T*4, cudaMemcpyHostToDevice));
            CHECK_CUDA(cudaMemcpy(d_user_ids, user_ids_arr, T*4, cudaMemcpyHostToDevice));

            // Warmup
            forward_multi_user(handle, cfg, layers, d_embd, d_lm_head, d_rms_final,
                                kv_caches, B, K, tokens_arr, positions_arr, user_ids_arr,
                                h_in_batch, h_out_batch, hidden_batch, norm_batch,
                                q_batch, k_batch, v_batch, attn_out_batch,
                                gate_batch, up_batch, h_gate_fp16, h_up_fp16);
            CHECK_CUDA(cudaDeviceSynchronize());

            // Timed runs
            cudaEventRecord(ev_start);
            for (int r = 0; r < n_runs; r++)
                forward_multi_user(handle, cfg, layers, d_embd, d_lm_head, d_rms_final,
                                    kv_caches, B, K, tokens_arr, positions_arr, user_ids_arr,
                                    h_in_batch, h_out_batch, hidden_batch, norm_batch,
                                    q_batch, k_batch, v_batch, attn_out_batch,
                                    gate_batch, up_batch, h_gate_fp16, h_up_fp16);
            cudaEventRecord(ev_stop); cudaEventSynchronize(ev_stop);
            float ms; cudaEventElapsedTime(&ms, ev_start, ev_stop);
            ms /= n_runs;

            // Per-user effective TPS at various acceptance rates
            float tps_07  = (0.7f * K + 1) / ms * 1000.0f;
            float tps_085 = (0.85f * K + 1) / ms * 1000.0f;
            float tps_09  = (0.9f * K + 1) / ms * 1000.0f;
            float agg_tps = (float)B * tps_085;  // aggregate TPS at α=0.85

            auto mark = [](float tps) { return tps >= 133 ? " ✓" : ""; };
            printf("B=%-2d K=%-2d T=%-3d %7.1f ms %7.0f%s %7.0f%s %7.0f%s   agg=%5.0f\n",
                   B, K, T, ms,
                   tps_07, mark(tps_07), tps_085, mark(tps_085),
                   tps_09, mark(tps_09), agg_tps);

            cudaFree(d_tokens); cudaFree(d_positions); cudaFree(d_user_ids);
        }
    }

    printf("\nTarget: 133 TPS per-user (TinyLlama 1.1B baseline)\n");

    // Cleanup
    cudaEventDestroy(ev_start); cudaEventDestroy(ev_stop);
    cublasDestroy(handle);
    for (int u = 0; u < MAX_USERS; u++) free_fp16_kv(kv_caches[u]);
    free(h_logits);
    munmap((void*)data, st.st_size);
    close(fd);

    return 0;
}

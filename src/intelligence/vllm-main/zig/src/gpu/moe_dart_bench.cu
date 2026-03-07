// MoE DART Batch Benchmark: REAM-Compressed Mixture-of-Experts on T4
//
// Proves that REAM-compressed MoE models (e.g., Qwen3-30B-A3B-REAM) can run
// on a single T4 with weight-sharing HGEMM for dense layers and per-token
// expert dispatch for MoE FFN layers.
//
// Architecture support: Qwen3 MoE (standard attention + routed experts + shared expert)
//   - Attention: FP16 HGEMM (dequant Q4→FP16 at load time)
//   - Router: FP16 matmul → softmax → TopK selection
//   - Routed experts: Q4 on GPU, dequant TopK experts on demand → FP16 HGEMM
//   - Shared expert: FP16 HGEMM (dequant at load time)
//   - KV cache: FP16
//
// Compile: nvcc -O3 -arch=sm_75 -lcublas -o moe_dart_bench moe_dart_bench.cu
// Run:     ./moe_dart_bench /path/to/qwen3-30b-a3b-ream.Q4_0.gguf

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <cstdint>
#include <cerrno>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cuda_fp16.h>
#include <cublas_v2.h>

#define CHECK_CUDA(call) do { \
    cudaError_t err = (call); \
    if (err != cudaSuccess) { \
        printf("CUDA error %s:%d: %s\n", __FILE__, __LINE__, cudaGetErrorString(err)); \
        exit(1); \
    } \
} while(0)

#define CHECK_CUBLAS(call) do { \
    cublasStatus_t st = (call); \
    if (st != CUBLAS_STATUS_SUCCESS) { \
        printf("cuBLAS error %s:%d: %d\n", __FILE__, __LINE__, (int)st); \
        exit(1); \
    } \
} while(0)

// ============================================================================
// Kernels (reused from multi_user_dart_bench.cu)
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

__global__ void fp16_swiglu_kernel(__half* __restrict__ gate,
                                    const __half* __restrict__ up, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) {
        float g = __half2float(gate[i]);
        float u = __half2float(up[i]);
        gate[i] = __float2half((g / (1.0f + expf(-g))) * u);
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

    const float* q_head = q + h * head_dim;
    for (int s = tid; s < seq_len; s += blockDim.x) {
        const __half* k_s = k_cache + s * n_kv_heads * head_dim + kv_h * head_dim;
        float dot = 0.0f;
        for (int d = 0; d < head_dim; d++)
            dot += q_head[d] * __half2float(k_s[d]);
        smem[s] = dot * scale;
    }
    __syncthreads();

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
            const __half* v_s = v_cache + s * n_kv_heads * head_dim + kv_h * head_dim;
            acc += smem[s] * __half2float(v_s[d]);
        }
        out_head[d] = acc;
    }
}

__global__ void store_kv_fp16(__half* __restrict__ dst,
                               const float* __restrict__ src, int kv_dim) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < kv_dim) dst[i] = __float2half(src[i]);
}

// Q4_0 → FP16 dequantization (full tensor)
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
// MoE-specific kernels
// ============================================================================

// Q4_0 → FP16 dequant for a SINGLE expert slice from stacked expert tensor
// Expert tensor layout: [N_experts, expert_ff, dim] stored as Q4_0
// Each expert has expert_ff rows of dim columns.
// expert_q4_base points to the start of the stacked tensor.
// We dequant expert_idx's slice into out[expert_ff × dim].
__global__ void dequant_expert_q4_fp16(
    __half* __restrict__ out,
    const uint8_t* __restrict__ expert_q4_base,
    int expert_idx, int expert_ff, int dim)
{
    int n_blocks_per_row = dim >> 5;
    int bytes_per_row = n_blocks_per_row * 18;
    long long expert_offset = (long long)expert_idx * expert_ff * bytes_per_row;
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= expert_ff * n_blocks_per_row) return;
    int row = idx / n_blocks_per_row;
    int col_block = idx % n_blocks_per_row;
    const uint8_t* bp = expert_q4_base + expert_offset + (long long)row * bytes_per_row + col_block * 18;
    float scale = __half2float(*reinterpret_cast<const __half*>(bp));
    int base = row * dim + col_block * 32;
    for (int j = 0; j < 16; j++) {
        uint8_t byte = bp[2 + j];
        out[base + j]      = __float2half(((float)(byte & 0xF) - 8.0f) * scale);
        out[base + j + 16] = __float2half(((float)(byte >> 4) - 8.0f) * scale);
    }
}

// Softmax + TopK on pre-computed router logits (from HGEMM)
// input: router_logits[n_experts] (FP16 from HGEMM)
// output: expert_ids[topk], expert_weights[topk] (normalized)
__global__ void softmax_topk_kernel(
    int* __restrict__ expert_ids,
    float* __restrict__ expert_weights,
    const __half* __restrict__ router_logits,  // [n_experts] FP16
    int n_experts, int topk)
{
    // Single-thread kernel — n_experts is small (96-128)
    if (threadIdx.x != 0) return;

    // Load logits to registers
    float scores[512];  // max experts
    float max_val = -1e30f;
    for (int e = 0; e < n_experts; e++) {
        scores[e] = __half2float(router_logits[e]);
        max_val = fmaxf(max_val, scores[e]);
    }

    // Softmax
    float sum_exp = 0.0f;
    for (int e = 0; e < n_experts; e++) { scores[e] = expf(scores[e] - max_val); sum_exp += scores[e]; }
    for (int e = 0; e < n_experts; e++) scores[e] /= sum_exp;

    // TopK selection
    for (int k = 0; k < topk; k++) {
        int best_e = -1;
        float best_w = -1.0f;
        for (int e = 0; e < n_experts; e++) {
            if (scores[e] > best_w) {
                bool taken = false;
                for (int j = 0; j < k; j++) if (expert_ids[j] == e) { taken = true; break; }
                if (!taken) { best_e = e; best_w = scores[e]; }
            }
        }
        expert_ids[k] = best_e;
        expert_weights[k] = best_w;
    }

    // Renormalize
    float wsum = 0.0f;
    for (int k = 0; k < topk; k++) wsum += expert_weights[k];
    if (wsum > 0.0f) for (int k = 0; k < topk; k++) expert_weights[k] /= wsum;
}

// Batched expert dequant: dequant TopK experts from stacked Q4 tensor in ONE kernel launch.
// Reads expert_ids from device memory. Output: stacked FP16 [topk × rows × cols].
__global__ void dequant_topk_experts_q4_fp16(
    __half* __restrict__ out,           // [topk × rows × cols] FP16
    const uint8_t* __restrict__ q4_base, // stacked Q4 [n_experts × rows × cols]
    const int* __restrict__ expert_ids,  // [topk] on device
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
    const uint8_t* bp = q4_base + expert_offset + (long long)row * bytes_per_row + col_block * 18;
    float scale = __half2float(*reinterpret_cast<const __half*>(bp));

    int out_base = ki * rows * cols + row * cols + col_block * 32;
    for (int j = 0; j < 16; j++) {
        uint8_t byte = bp[2 + j];
        out[out_base + j]      = __float2half(((float)(byte & 0xF) - 8.0f) * scale);
        out[out_base + j + 16] = __float2half(((float)(byte >> 4) - 8.0f) * scale);
    }
}

// Gather TopK experts from union buffer to contiguous staging buffer
// union_indices[topk]: which union slot each of the token's TopK experts maps to
__global__ void gather_experts_kernel(
    __half* __restrict__ dst,       // [topk × rows × cols] contiguous
    const __half* __restrict__ src,  // [union_size × rows × cols]
    const int* __restrict__ union_indices, // [topk]
    int topk, int rows, int cols)
{
    int total = topk * rows * cols;
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= total) return;
    int ki = idx / (rows * cols);
    int elem = idx % (rows * cols);
    int u_idx = union_indices[ki];
    dst[idx] = src[(long long)u_idx * rows * cols + elem];
}

// Weighted scatter-add: for each expert k, out[i] += weights[k] * in[k*dim + i]
__global__ void weighted_scatter_add_kernel(
    float* __restrict__ out,
    const __half* __restrict__ in,  // [topk × dim] FP16
    const float* __restrict__ weights,  // [topk] on device
    int topk, int dim)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= dim) return;
    float acc = 0.0f;
    for (int k = 0; k < topk; k++)
        acc += weights[k] * __half2float(in[k * dim + i]);
    out[i] += acc;
}

// Weighted accumulate: out[i] += weight * in[i]
__global__ void weighted_add_kernel(float* __restrict__ out,
                                     const float* __restrict__ in,
                                     float weight, int dim) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < dim) out[i] += weight * in[i];
}

// ============================================================================
// GGUF Parser (extended for MoE)
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
// MoE Model structures
// ============================================================================

struct MoEConfig {
    int dim, n_layers, n_heads, n_kv_heads, vocab;
    int n_experts, n_experts_topk, expert_ff;
    int has_shared_expert;  // 1 if model has shared expert
    float rope_base;
};

// Dense attention weights (dequant to FP16 at load time)
struct AttnWeights {
    __half *wq, *wk, *wv, *wo;
    float *rms_attn, *rms_ffn;
};

// MoE FFN weights per layer
struct MoEFFNWeights {
    // Router: [n_experts × dim] FP16
    __half* router_w;
    // Shared expert: FP16 (dequant at load time)
    __half *shared_gate, *shared_up, *shared_down;
    // Routed experts: Q4_0 on GPU (dequant on demand)
    // Stacked: [n_experts × expert_ff × dim] for gate/up
    //          [n_experts × dim × expert_ff] for down
    uint8_t *experts_gate_q4, *experts_up_q4, *experts_down_q4;
};

// Per-user FP16 KV cache (same as dense bench)
struct FP16KVCache {
    __half* key;
    __half* val;
    int max_seq, kv_dim, n_layers, seq_len;
};

void init_fp16_kv(FP16KVCache& kv, int n_layers, int max_seq, int kv_dim) {
    kv.n_layers = n_layers; kv.max_seq = max_seq; kv.kv_dim = kv_dim; kv.seq_len = 0;
    size_t bytes = (size_t)n_layers * max_seq * kv_dim * sizeof(__half);
    CHECK_CUDA(cudaMalloc(&kv.key, bytes));
    CHECK_CUDA(cudaMalloc(&kv.val, bytes));
    CHECK_CUDA(cudaMemset(kv.key, 0, bytes));
    CHECK_CUDA(cudaMemset(kv.val, 0, bytes));
}

void free_fp16_kv(FP16KVCache& kv) { cudaFree(kv.key); cudaFree(kv.val); }

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
// MoE single-token forward pass
// ============================================================================

void forward_moe_single(
    cublasHandle_t handle, MoEConfig& cfg,
    AttnWeights* attn_layers, MoEFFNWeights* moe_layers,
    __half* d_embd, __half* d_lm_head, float* d_rms_final,
    // Scratch buffers
    float* hidden, float* norm, float* q, float* k, float* v,
    float* attn_out, float* moe_out,
    __half* h_in, __half* h_out,
    // Expert scratch (FP16, sized for 1 expert: expert_ff × dim)
    __half* expert_gate_fp16, __half* expert_up_fp16, __half* expert_down_fp16,
    // Expert output scratch
    float* expert_out,
    // Router output
    int* d_expert_ids, float* d_expert_weights,
    FP16KVCache& kv, int token, int pos,
    bool skip_dequant = false)  // skip dequant for warm-cache benchmark
{
    int dim = cfg.dim, eff = cfg.expert_ff;
    int n_heads = cfg.n_heads, n_kv_heads = cfg.n_kv_heads;
    int head_dim = dim / n_heads;
    int kv_dim = n_kv_heads * head_dim;
    int seq_len = pos + 1;
    __half alpha_h = __float2half(1.0f), beta_h = __float2half(0.0f);

    // Embedding
    embedding_kernel<<<(dim+255)/256, 256>>>(hidden, d_embd, token, dim);

    for (int l = 0; l < cfg.n_layers; l++) {
        AttnWeights& aw = attn_layers[l];
        MoEFFNWeights& mw = moe_layers[l];

        // ---- Attention (same as dense model) ----
        rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(norm, hidden, aw.rms_attn, dim, 1e-6f);

        fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(h_in, norm, dim);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, 1, dim, &alpha_h, aw.wq, dim, h_in, dim, &beta_h, h_out, dim);
        fp16_to_fp32_kernel<<<(dim+255)/256, 256>>>(q, h_out, dim);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, kv_dim, 1, dim, &alpha_h, aw.wk, dim, h_in, dim, &beta_h, h_out, kv_dim);
        fp16_to_fp32_kernel<<<(kv_dim+255)/256, 256>>>(k, h_out, kv_dim);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, kv_dim, 1, dim, &alpha_h, aw.wv, dim, h_in, dim, &beta_h, h_out, kv_dim);
        fp16_to_fp32_kernel<<<(kv_dim+255)/256, 256>>>(v, h_out, kv_dim);

        rope_kernel<<<(dim+255)/256, 256>>>(q, pos, head_dim, cfg.rope_base, n_heads);
        rope_kernel<<<(kv_dim+255)/256, 256>>>(k, pos, head_dim, cfg.rope_base, n_kv_heads);

        store_kv_fp16<<<(kv_dim+255)/256, 256>>>(kv_key_ptr(kv, l, pos), k, kv_dim);
        store_kv_fp16<<<(kv_dim+255)/256, 256>>>(kv_val_ptr(kv, l, pos), v, kv_dim);

        float scale = 1.0f / sqrtf((float)head_dim);
        int smem_attn = seq_len * sizeof(float);
        if (smem_attn < 48*1024)
            decode_attention_fp16kv<<<n_heads, 256, smem_attn>>>(
                attn_out, q, kv_key_layer(kv, l), kv_val_layer(kv, l),
                n_heads, n_kv_heads, head_dim, seq_len, scale, kv.max_seq);

        fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(h_in, attn_out, dim);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, 1, dim, &alpha_h, aw.wo, dim, h_in, dim, &beta_h, h_out, dim);
        fp16_to_fp32_kernel<<<(dim+255)/256, 256>>>(norm, h_out, dim);
        vecadd_kernel<<<(dim+255)/256, 256>>>(hidden, hidden, norm, dim);

        // ---- MoE FFN (optimized: batched dequant + strided HGEMM) ----
        rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(norm, hidden, aw.rms_ffn, dim, 1e-6f);

        // Zero MoE output accumulator
        CHECK_CUDA(cudaMemsetAsync(moe_out, 0, dim * sizeof(float)));

        // Router: HGEMM for logits + lightweight softmax+TopK
        fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(h_in, norm, dim);
        // router_w is [n_experts × dim], h_in is [dim × 1]
        // HGEMM: [n_experts × dim]^T @ ... no, we want router_w @ h_in = [n_experts × 1]
        // = CUBLAS_OP_T on router_w: out[n_experts] = router_w^T ... actually:
        // router_w stored row-major [n_experts × dim], cuBLAS sees col-major [dim × n_experts]
        // We want out = router_w @ h_in = [n_experts × 1]
        // cuBLAS col-major: C(n_experts,1) = A(n_experts,dim) @ B(dim,1)
        //   = op(A_colmaj) @ B, A_colmaj is [dim × n_experts], so op=CUBLAS_OP_T
        __half* router_logits = h_out;  // temp, first n_experts elements
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N,
            cfg.n_experts, 1, dim, &alpha_h,
            mw.router_w, dim,  // [dim × n_experts] col-major = [n_experts × dim] row-major
            h_in, dim,
            &beta_h, router_logits, cfg.n_experts);
        softmax_topk_kernel<<<1, 1>>>(
            d_expert_ids, d_expert_weights,
            router_logits, cfg.n_experts, cfg.n_experts_topk);

        // Batched dequant: all TopK experts in 3 kernel launches (gate, up, down)
        // expert_ids read from device memory — no host roundtrip!
        int topk = cfg.n_experts_topk;
        if (!skip_dequant) {
            int gate_total = topk * eff * (dim >> 5);
            int down_total = topk * dim * (eff >> 5);
            dequant_topk_experts_q4_fp16<<<(gate_total+255)/256, 256>>>(
                expert_gate_fp16, mw.experts_gate_q4, d_expert_ids, topk, eff, dim);
            dequant_topk_experts_q4_fp16<<<(gate_total+255)/256, 256>>>(
                expert_up_fp16, mw.experts_up_q4, d_expert_ids, topk, eff, dim);
            dequant_topk_experts_q4_fp16<<<(down_total+255)/256, 256>>>(
                expert_down_fp16, mw.experts_down_q4, d_expert_ids, topk, dim, eff);
        }

        // Batched HGEMM: all TopK gate projections in one call
        // expert_gate_fp16 = [topk × eff × dim], h_in = [dim × 1] (broadcast)
        // We use strided batched HGEMM: A[k] = expert_gate[k], B = h_in (same for all), C[k] = gate_out[k]
        // gate_out stored in h_out: [topk × eff]
        long long strideA_gate = (long long)eff * dim;   // stride between expert weights
        long long strideC_gate = (long long)eff;          // stride between expert outputs
        CHECK_CUBLAS(cublasHgemmStridedBatched(handle,
            CUBLAS_OP_T, CUBLAS_OP_N,
            eff, 1, dim,                          // M, N, K
            &alpha_h,
            expert_gate_fp16, dim, strideA_gate,  // A: [dim × eff] per expert (col-major)
            h_in, dim, 0,                         // B: [dim × 1] shared (stride=0)
            &beta_h,
            h_out, eff, strideC_gate,             // C: [eff × 1] per expert
            topk));

        // Up projections: same pattern, output into h_out + topk*eff
        __half* h_up_results = h_out + topk * eff;
        CHECK_CUBLAS(cublasHgemmStridedBatched(handle,
            CUBLAS_OP_T, CUBLAS_OP_N,
            eff, 1, dim,
            &alpha_h,
            expert_up_fp16, dim, strideA_gate,
            h_in, dim, 0,
            &beta_h,
            h_up_results, eff, strideC_gate,
            topk));

        // Fused SwiGLU for all TopK experts at once
        fp16_swiglu_kernel<<<(topk*eff+255)/256, 256>>>(h_out, h_up_results, topk * eff);

        // Down projections: [topk × dim × eff] @ [topk × eff × 1] → [topk × dim × 1]
        __half* h_down_results = h_up_results + topk * eff;
        long long strideA_down = (long long)dim * eff;
        long long strideB_down = (long long)eff;
        long long strideC_down = (long long)dim;
        CHECK_CUBLAS(cublasHgemmStridedBatched(handle,
            CUBLAS_OP_T, CUBLAS_OP_N,
            dim, 1, eff,
            &alpha_h,
            expert_down_fp16, eff, strideA_down,
            h_out, eff, strideB_down,             // each expert's SwiGLU output
            &beta_h,
            h_down_results, dim, strideC_down,
            topk));

        // Weighted scatter-add: combine all TopK expert outputs using router weights
        weighted_scatter_add_kernel<<<(dim+255)/256, 256>>>(
            moe_out, h_down_results, d_expert_weights, topk, dim);

        // Shared expert (always active, FP16 weights)
        if (cfg.has_shared_expert && mw.shared_gate != nullptr) {
            __half* sh_gate_out = h_down_results + topk * dim;
            __half* sh_up_out = sh_gate_out + eff;
            __half* sh_down_out = sh_up_out + eff;
            cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, eff, 1, dim,
                         &alpha_h, mw.shared_gate, dim, h_in, dim, &beta_h, sh_gate_out, eff);
            cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, eff, 1, dim,
                         &alpha_h, mw.shared_up, dim, h_in, dim, &beta_h, sh_up_out, eff);
            fp16_swiglu_kernel<<<(eff+255)/256, 256>>>(sh_gate_out, sh_up_out, eff);
            cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, 1, eff,
                         &alpha_h, mw.shared_down, eff, sh_gate_out, eff, &beta_h, sh_down_out, dim);
            fp16_to_fp32_kernel<<<(dim+255)/256, 256>>>(expert_out, sh_down_out, dim);
            vecadd_kernel<<<(dim+255)/256, 256>>>(moe_out, moe_out, expert_out, dim);
        }

        // Residual: hidden += moe_out
        vecadd_kernel<<<(dim+255)/256, 256>>>(hidden, hidden, moe_out, dim);
    }

    // Final norm + LM head
    rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(norm, hidden, d_rms_final, dim, 1e-6f);
    fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(h_in, norm, dim);
    cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, cfg.vocab, 1, dim,
                 &alpha_h, d_lm_head, dim, h_in, dim, &beta_h, h_out, cfg.vocab);
}

// ============================================================================
// MoE DART batch forward: K tokens, dequant union of experts once per layer
// ============================================================================

void forward_moe_batch(
    cublasHandle_t handle, MoEConfig& cfg,
    AttnWeights* attn_layers, MoEFFNWeights* moe_layers,
    __half* d_embd, __half* d_lm_head, float* d_rms_final,
    float* hidden, float* norm, float* q, float* k_buf, float* v_buf,
    float* attn_out, float* moe_out,
    __half* h_in, __half* h_out,
    __half* expert_gate_fp16, __half* expert_up_fp16, __half* expert_down_fp16,
    float* expert_out,
    int* d_expert_ids, float* d_expert_weights,  // [K × topk] each
    int* d_union_ids,   // pre-allocated [max_union] on GPU
    FP16KVCache& kv, int* tokens, int K, int start_pos)
{
    int dim = cfg.dim, eff = cfg.expert_ff;
    int n_heads = cfg.n_heads, n_kv_heads = cfg.n_kv_heads;
    int head_dim = dim / n_heads;
    int kv_dim = n_kv_heads * head_dim;
    int topk = cfg.n_experts_topk;
    __half alpha_h = __float2half(1.0f), beta_h = __float2half(0.0f);

    // Per-token hidden states stored sequentially in hidden: use offset t*dim
    // But we only have one hidden buffer — process layer-by-layer, token-by-token
    // Use a flat hidden_batch buffer: hidden points to [K × dim]

    // Embedding for all K tokens
    for (int t = 0; t < K; t++)
        embedding_kernel<<<(dim+255)/256, 256>>>(hidden + t*dim, d_embd, tokens[t], dim);

    for (int l = 0; l < cfg.n_layers; l++) {
        AttnWeights& aw = attn_layers[l];
        MoEFFNWeights& mw = moe_layers[l];

        // ---- Attention: per-token (each at different KV position) ----
        for (int t = 0; t < K; t++) {
            float* h_t = hidden + t * dim;
            int pos = start_pos + t;
            int seq_len = pos + 1;

            rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(norm, h_t, aw.rms_attn, dim, 1e-6f);
            fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(h_in, norm, dim);

            cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, 1, dim, &alpha_h, aw.wq, dim, h_in, dim, &beta_h, h_out, dim);
            fp16_to_fp32_kernel<<<(dim+255)/256, 256>>>(q, h_out, dim);
            cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, kv_dim, 1, dim, &alpha_h, aw.wk, dim, h_in, dim, &beta_h, h_out, kv_dim);
            fp16_to_fp32_kernel<<<(kv_dim+255)/256, 256>>>(k_buf, h_out, kv_dim);
            cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, kv_dim, 1, dim, &alpha_h, aw.wv, dim, h_in, dim, &beta_h, h_out, kv_dim);
            fp16_to_fp32_kernel<<<(kv_dim+255)/256, 256>>>(v_buf, h_out, kv_dim);

            rope_kernel<<<(dim+255)/256, 256>>>(q, pos, head_dim, cfg.rope_base, n_heads);
            rope_kernel<<<(kv_dim+255)/256, 256>>>(k_buf, pos, head_dim, cfg.rope_base, n_kv_heads);
            store_kv_fp16<<<(kv_dim+255)/256, 256>>>(kv_key_ptr(kv, l, pos), k_buf, kv_dim);
            store_kv_fp16<<<(kv_dim+255)/256, 256>>>(kv_val_ptr(kv, l, pos), v_buf, kv_dim);

            float scale = 1.0f / sqrtf((float)head_dim);
            int smem_attn = seq_len * sizeof(float);
            if (smem_attn < 48*1024)
                decode_attention_fp16kv<<<n_heads, 256, smem_attn>>>(
                    attn_out, q, kv_key_layer(kv, l), kv_val_layer(kv, l),
                    n_heads, n_kv_heads, head_dim, seq_len, scale, kv.max_seq);

            fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(h_in, attn_out, dim);
            cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, 1, dim, &alpha_h, aw.wo, dim, h_in, dim, &beta_h, h_out, dim);
            fp16_to_fp32_kernel<<<(dim+255)/256, 256>>>(norm, h_out, dim);
            vecadd_kernel<<<(dim+255)/256, 256>>>(h_t, h_t, norm, dim);
        }

        // ---- MoE FFN: dequant union of experts once, process all K tokens ----
        // Step 1: Run router for all K tokens, collect expert IDs on host
        int h_all_expert_ids[16 * 16] = {};   // K(max16) × topk(max16)
        float h_all_expert_weights[16 * 16] = {};

        for (int t = 0; t < K; t++) {
            float* h_t = hidden + t * dim;
            rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(norm, h_t, aw.rms_ffn, dim, 1e-6f);

            // Save normed hidden for this token (we'll need it for expert forward)
            // Store in hidden_batch_normed area: expert_out used as temp for FP32 norm
            // Actually, store FP16 normed hidden for each token in h_out offset area
            fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(h_in, norm, dim);

            // Router HGEMM
            __half* router_logits = h_out;
            cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N,
                cfg.n_experts, 1, dim, &alpha_h,
                mw.router_w, dim, h_in, dim,
                &beta_h, router_logits, cfg.n_experts);

            int* d_ids_t = d_expert_ids + t * topk;
            float* d_wts_t = d_expert_weights + t * topk;
            softmax_topk_kernel<<<1, 1>>>(d_ids_t, d_wts_t, router_logits, cfg.n_experts, topk);

            // Copy this token's router results to host
            CHECK_CUDA(cudaMemcpy(h_all_expert_ids + t * topk, d_ids_t, topk * sizeof(int), cudaMemcpyDeviceToHost));
            CHECK_CUDA(cudaMemcpy(h_all_expert_weights + t * topk, d_wts_t, topk * sizeof(float), cudaMemcpyDeviceToHost));
        }

        // Step 2: Compute union of expert IDs
        int union_ids[256];
        int union_size = 0;
        for (int t = 0; t < K; t++) {
            for (int ki = 0; ki < topk; ki++) {
                int e = h_all_expert_ids[t * topk + ki];
                if (e < 0) continue;
                bool found = false;
                for (int u = 0; u < union_size; u++) if (union_ids[u] == e) { found = true; break; }
                if (!found) union_ids[union_size++] = e;
            }
        }

        // Step 3: Dequant union set — upload union_ids to pre-allocated GPU buffer
        CHECK_CUDA(cudaMemcpy(d_union_ids, union_ids, union_size * sizeof(int), cudaMemcpyHostToDevice));

        int gate_total_u = union_size * eff * (dim >> 5);
        int down_total_u = union_size * dim * (eff >> 5);
        dequant_topk_experts_q4_fp16<<<(gate_total_u+255)/256, 256>>>(
            expert_gate_fp16, mw.experts_gate_q4, d_union_ids, union_size, eff, dim);
        dequant_topk_experts_q4_fp16<<<(gate_total_u+255)/256, 256>>>(
            expert_up_fp16, mw.experts_up_q4, d_union_ids, union_size, eff, dim);
        dequant_topk_experts_q4_fp16<<<(down_total_u+255)/256, 256>>>(
            expert_down_fp16, mw.experts_down_q4, d_union_ids, union_size, dim, eff);

        // Step 4: For each token, run its TopK experts using cached FP16 weights
        for (int t = 0; t < K; t++) {
            float* h_t = hidden + t * dim;

            rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(norm, h_t, aw.rms_ffn, dim, 1e-6f);
            fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(h_in, norm, dim);
            CHECK_CUDA(cudaMemsetAsync(moe_out, 0, dim * sizeof(float)));

            for (int ki = 0; ki < topk; ki++) {
                int e = h_all_expert_ids[t * topk + ki];
                float w = h_all_expert_weights[t * topk + ki];
                if (e < 0) continue;

                // Find this expert's index in the union set
                int u_idx = -1;
                for (int u = 0; u < union_size; u++) if (union_ids[u] == e) { u_idx = u; break; }
                if (u_idx < 0) continue;

                __half* gate_w = expert_gate_fp16 + (long long)u_idx * eff * dim;
                __half* up_w   = expert_up_fp16   + (long long)u_idx * eff * dim;
                __half* down_w = expert_down_fp16  + (long long)u_idx * dim * eff;

                __half* gate_out = h_out;
                cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, eff, 1, dim,
                    &alpha_h, gate_w, dim, h_in, dim, &beta_h, gate_out, eff);
                __half* up_out = gate_out + eff;
                cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, eff, 1, dim,
                    &alpha_h, up_w, dim, h_in, dim, &beta_h, up_out, eff);
                fp16_swiglu_kernel<<<(eff+255)/256, 256>>>(gate_out, up_out, eff);
                __half* down_out = up_out + eff;
                cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, 1, eff,
                    &alpha_h, down_w, eff, gate_out, eff, &beta_h, down_out, dim);
                fp16_to_fp32_kernel<<<(dim+255)/256, 256>>>(expert_out, down_out, dim);
                weighted_add_kernel<<<(dim+255)/256, 256>>>(moe_out, expert_out, w, dim);
            }

            // Shared expert
            if (cfg.has_shared_expert && mw.shared_gate != nullptr) {
                __half* sg = h_out; __half* su = sg + eff; __half* sd = su + eff;
                cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, eff, 1, dim, &alpha_h, mw.shared_gate, dim, h_in, dim, &beta_h, sg, eff);
                cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, eff, 1, dim, &alpha_h, mw.shared_up, dim, h_in, dim, &beta_h, su, eff);
                fp16_swiglu_kernel<<<(eff+255)/256, 256>>>(sg, su, eff);
                cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, 1, eff, &alpha_h, mw.shared_down, eff, sg, eff, &beta_h, sd, dim);
                fp16_to_fp32_kernel<<<(dim+255)/256, 256>>>(expert_out, sd, dim);
                vecadd_kernel<<<(dim+255)/256, 256>>>(moe_out, moe_out, expert_out, dim);
            }

            vecadd_kernel<<<(dim+255)/256, 256>>>(h_t, h_t, moe_out, dim);
        }
    }

    // Final norm + LM head (last token only for next-token prediction)
    float* h_last = hidden + (K-1) * dim;
    rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(norm, h_last, d_rms_final, dim, 1e-6f);
    fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(h_in, norm, dim);
    cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, cfg.vocab, 1, dim,
                 &alpha_h, d_lm_head, dim, h_in, dim, &beta_h, h_out, cfg.vocab);
}

// ============================================================================
// MoE expert offloading forward: experts live in CPU, transfer per layer
// ============================================================================

void forward_moe_offload(
    cublasHandle_t handle, MoEConfig& cfg,
    AttnWeights* attn_layers, MoEFFNWeights* moe_layers,
    // CPU expert weight pointers per layer
    const uint8_t** h_exp_gate, const uint8_t** h_exp_up, const uint8_t** h_exp_down,
    // GPU staging for Q4 expert data (TopK experts worth)
    uint8_t* d_q4_staging,
    __half* d_embd, __half* d_lm_head, float* d_rms_final,
    float* hidden, float* norm, float* q, float* k_buf, float* v_buf,
    float* attn_out, float* moe_out,
    __half* h_in, __half* h_out,
    __half* expert_gate_fp16, __half* expert_up_fp16, __half* expert_down_fp16,
    float* expert_out,
    int* d_expert_ids, float* d_expert_weights,
    FP16KVCache& kv, int token, int pos)
{
    int dim = cfg.dim, eff = cfg.expert_ff;
    int n_heads = cfg.n_heads, n_kv_heads = cfg.n_kv_heads;
    int head_dim = dim / n_heads;
    int kv_dim = n_kv_heads * head_dim;
    int topk = cfg.n_experts_topk;
    __half alpha_h = __float2half(1.0f), beta_h = __float2half(0.0f);

    // Per-expert Q4 byte sizes
    size_t gate_q4_per_expert = (size_t)eff * (dim / 32) * 18;
    size_t up_q4_per_expert = gate_q4_per_expert;
    size_t down_q4_per_expert = (size_t)dim * (eff / 32) * 18;

    embedding_kernel<<<(dim+255)/256, 256>>>(hidden, d_embd, token, dim);

    for (int l = 0; l < cfg.n_layers; l++) {
        AttnWeights& aw = attn_layers[l];
        MoEFFNWeights& mw = moe_layers[l];
        int seq_len = pos + 1;

        // ---- Attention (same as on-GPU version, weights in VRAM) ----
        rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(norm, hidden, aw.rms_attn, dim, 1e-6f);
        fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(h_in, norm, dim);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, 1, dim, &alpha_h, aw.wq, dim, h_in, dim, &beta_h, h_out, dim);
        fp16_to_fp32_kernel<<<(dim+255)/256, 256>>>(q, h_out, dim);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, kv_dim, 1, dim, &alpha_h, aw.wk, dim, h_in, dim, &beta_h, h_out, kv_dim);
        fp16_to_fp32_kernel<<<(kv_dim+255)/256, 256>>>(k_buf, h_out, kv_dim);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, kv_dim, 1, dim, &alpha_h, aw.wv, dim, h_in, dim, &beta_h, h_out, kv_dim);
        fp16_to_fp32_kernel<<<(kv_dim+255)/256, 256>>>(v_buf, h_out, kv_dim);

        rope_kernel<<<(dim+255)/256, 256>>>(q, pos, head_dim, cfg.rope_base, n_heads);
        rope_kernel<<<(kv_dim+255)/256, 256>>>(k_buf, pos, head_dim, cfg.rope_base, n_kv_heads);
        store_kv_fp16<<<(kv_dim+255)/256, 256>>>(kv_key_ptr(kv, l, pos), k_buf, kv_dim);
        store_kv_fp16<<<(kv_dim+255)/256, 256>>>(kv_val_ptr(kv, l, pos), v_buf, kv_dim);

        float scale = 1.0f / sqrtf((float)head_dim);
        int smem_attn = seq_len * sizeof(float);
        if (smem_attn < 48*1024)
            decode_attention_fp16kv<<<n_heads, 256, smem_attn>>>(
                attn_out, q, kv_key_layer(kv, l), kv_val_layer(kv, l),
                n_heads, n_kv_heads, head_dim, seq_len, scale, kv.max_seq);

        fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(h_in, attn_out, dim);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, 1, dim, &alpha_h, aw.wo, dim, h_in, dim, &beta_h, h_out, dim);
        fp16_to_fp32_kernel<<<(dim+255)/256, 256>>>(norm, h_out, dim);
        vecadd_kernel<<<(dim+255)/256, 256>>>(hidden, hidden, norm, dim);

        // ---- MoE FFN with expert offloading from CPU ----
        rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(norm, hidden, aw.rms_ffn, dim, 1e-6f);
        CHECK_CUDA(cudaMemsetAsync(moe_out, 0, dim * sizeof(float)));

        // Router
        fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(h_in, norm, dim);
        __half* router_logits = h_out;
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N,
            cfg.n_experts, 1, dim, &alpha_h,
            mw.router_w, dim, h_in, dim,
            &beta_h, router_logits, cfg.n_experts);
        softmax_topk_kernel<<<1, 1>>>(d_expert_ids, d_expert_weights, router_logits, cfg.n_experts, topk);

        // Copy router results to host to know which experts to transfer
        int h_ids[16]; float h_wts[16];
        CHECK_CUDA(cudaMemcpy(h_ids, d_expert_ids, topk * sizeof(int), cudaMemcpyDeviceToHost));
        CHECK_CUDA(cudaMemcpy(h_wts, d_expert_weights, topk * sizeof(float), cudaMemcpyDeviceToHost));

        // Transfer TopK expert Q4 weights from CPU → GPU staging, then dequant
        for (int ki = 0; ki < topk; ki++) {
            int e = h_ids[ki];
            if (e < 0) continue;

            // CPU → GPU: gate weights for expert e
            const uint8_t* h_gate = h_exp_gate[l] + (size_t)e * gate_q4_per_expert;
            const uint8_t* h_up   = h_exp_up[l]   + (size_t)e * up_q4_per_expert;
            const uint8_t* h_down = h_exp_down[l]  + (size_t)e * down_q4_per_expert;

            uint8_t* stg_gate = d_q4_staging;
            uint8_t* stg_up   = stg_gate + gate_q4_per_expert;
            uint8_t* stg_down = stg_up + up_q4_per_expert;

            CHECK_CUDA(cudaMemcpy(stg_gate, h_gate, gate_q4_per_expert, cudaMemcpyHostToDevice));
            CHECK_CUDA(cudaMemcpy(stg_up,   h_up,   up_q4_per_expert, cudaMemcpyHostToDevice));
            CHECK_CUDA(cudaMemcpy(stg_down, h_down,  down_q4_per_expert, cudaMemcpyHostToDevice));

            // Dequant single expert: Q4 staging → FP16
            int gate_blocks = (eff * (dim >> 5) + 255) / 256;
            int down_blocks = (dim * (eff >> 5) + 255) / 256;
            __half* fp16_gate = expert_gate_fp16 + (long long)ki * eff * dim;
            __half* fp16_up   = expert_up_fp16   + (long long)ki * eff * dim;
            __half* fp16_down = expert_down_fp16  + (long long)ki * dim * eff;
            dequant_q4_fp16<<<gate_blocks, 256>>>(fp16_gate, stg_gate, eff, dim);
            dequant_q4_fp16<<<gate_blocks, 256>>>(fp16_up,   stg_up,   eff, dim);
            dequant_q4_fp16<<<down_blocks, 256>>>(fp16_down, stg_down, dim, eff);

            // HGEMM for this expert
            __half* gate_out = h_out;
            cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, eff, 1, dim,
                &alpha_h, fp16_gate, dim, h_in, dim, &beta_h, gate_out, eff);
            __half* up_out = gate_out + eff;
            cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, eff, 1, dim,
                &alpha_h, fp16_up, dim, h_in, dim, &beta_h, up_out, eff);
            fp16_swiglu_kernel<<<(eff+255)/256, 256>>>(gate_out, up_out, eff);
            __half* down_out = up_out + eff;
            cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, 1, eff,
                &alpha_h, fp16_down, eff, gate_out, eff, &beta_h, down_out, dim);

            fp16_to_fp32_kernel<<<(dim+255)/256, 256>>>(expert_out, down_out, dim);
            weighted_add_kernel<<<(dim+255)/256, 256>>>(moe_out, expert_out, h_wts[ki], dim);
        }

        // Shared expert (still on GPU)
        if (cfg.has_shared_expert && mw.shared_gate != nullptr) {
            __half* sg = h_out; __half* su = sg + eff; __half* sd = su + eff;
            cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, eff, 1, dim, &alpha_h, mw.shared_gate, dim, h_in, dim, &beta_h, sg, eff);
            cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, eff, 1, dim, &alpha_h, mw.shared_up, dim, h_in, dim, &beta_h, su, eff);
            fp16_swiglu_kernel<<<(eff+255)/256, 256>>>(sg, su, eff);
            cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, 1, eff, &alpha_h, mw.shared_down, eff, sg, eff, &beta_h, sd, dim);
            fp16_to_fp32_kernel<<<(dim+255)/256, 256>>>(expert_out, sd, dim);
            vecadd_kernel<<<(dim+255)/256, 256>>>(moe_out, moe_out, expert_out, dim);
        }

        vecadd_kernel<<<(dim+255)/256, 256>>>(hidden, hidden, moe_out, dim);
    }

    // Final norm + LM head
    rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(norm, hidden, d_rms_final, dim, 1e-6f);
    fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(h_in, norm, dim);
    cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, cfg.vocab, 1, dim,
                 &alpha_h, d_lm_head, dim, h_in, dim, &beta_h, h_out, cfg.vocab);
}

// ============================================================================
// MoE offloading v2: pinned staging + batched transfers (3 calls/layer)
// ============================================================================

void forward_moe_offload_pinned(
    cublasHandle_t handle, MoEConfig& cfg,
    AttnWeights* attn_layers, MoEFFNWeights* moe_layers,
    const uint8_t** h_exp_gate, const uint8_t** h_exp_up, const uint8_t** h_exp_down,
    // Pinned CPU staging buffers [topk × per_expert_bytes] each
    uint8_t* h_pin_gate, uint8_t* h_pin_up, uint8_t* h_pin_down,
    // GPU staging for batched Q4 data [topk × per_expert_bytes]
    uint8_t* d_q4_gate_batch, uint8_t* d_q4_up_batch, uint8_t* d_q4_down_batch,
    __half* d_embd, __half* d_lm_head, float* d_rms_final,
    float* hidden, float* norm, float* q, float* k_buf, float* v_buf,
    float* attn_out, float* moe_out,
    __half* h_in, __half* h_out,
    __half* expert_gate_fp16, __half* expert_up_fp16, __half* expert_down_fp16,
    float* expert_out,
    int* d_expert_ids, float* d_expert_weights,
    FP16KVCache& kv, int token, int pos)
{
    int dim = cfg.dim, eff = cfg.expert_ff;
    int n_heads = cfg.n_heads, n_kv_heads = cfg.n_kv_heads;
    int head_dim = dim / n_heads;
    int kv_dim = n_kv_heads * head_dim;
    int topk = cfg.n_experts_topk;
    __half alpha_h = __float2half(1.0f), beta_h = __float2half(0.0f);

    size_t gate_q4_per_expert = (size_t)eff * (dim / 32) * 18;
    size_t up_q4_per_expert = gate_q4_per_expert;
    size_t down_q4_per_expert = (size_t)dim * (eff / 32) * 18;

    embedding_kernel<<<(dim+255)/256, 256>>>(hidden, d_embd, token, dim);

    for (int l = 0; l < cfg.n_layers; l++) {
        AttnWeights& aw = attn_layers[l];
        MoEFFNWeights& mw = moe_layers[l];
        int seq_len = pos + 1;

        // ---- Attention (weights in VRAM) ----
        rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(norm, hidden, aw.rms_attn, dim, 1e-6f);
        fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(h_in, norm, dim);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, 1, dim, &alpha_h, aw.wq, dim, h_in, dim, &beta_h, h_out, dim);
        fp16_to_fp32_kernel<<<(dim+255)/256, 256>>>(q, h_out, dim);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, kv_dim, 1, dim, &alpha_h, aw.wk, dim, h_in, dim, &beta_h, h_out, kv_dim);
        fp16_to_fp32_kernel<<<(kv_dim+255)/256, 256>>>(k_buf, h_out, kv_dim);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, kv_dim, 1, dim, &alpha_h, aw.wv, dim, h_in, dim, &beta_h, h_out, kv_dim);
        fp16_to_fp32_kernel<<<(kv_dim+255)/256, 256>>>(v_buf, h_out, kv_dim);

        rope_kernel<<<(dim+255)/256, 256>>>(q, pos, head_dim, cfg.rope_base, n_heads);
        rope_kernel<<<(kv_dim+255)/256, 256>>>(k_buf, pos, head_dim, cfg.rope_base, n_kv_heads);
        store_kv_fp16<<<(kv_dim+255)/256, 256>>>(kv_key_ptr(kv, l, pos), k_buf, kv_dim);
        store_kv_fp16<<<(kv_dim+255)/256, 256>>>(kv_val_ptr(kv, l, pos), v_buf, kv_dim);

        float scale = 1.0f / sqrtf((float)head_dim);
        int smem_attn = seq_len * sizeof(float);
        if (smem_attn < 48*1024)
            decode_attention_fp16kv<<<n_heads, 256, smem_attn>>>(
                attn_out, q, kv_key_layer(kv, l), kv_val_layer(kv, l),
                n_heads, n_kv_heads, head_dim, seq_len, scale, kv.max_seq);

        fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(h_in, attn_out, dim);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, 1, dim, &alpha_h, aw.wo, dim, h_in, dim, &beta_h, h_out, dim);
        fp16_to_fp32_kernel<<<(dim+255)/256, 256>>>(norm, h_out, dim);
        vecadd_kernel<<<(dim+255)/256, 256>>>(hidden, hidden, norm, dim);

        // ---- MoE FFN: pinned batched offload ----
        rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(norm, hidden, aw.rms_ffn, dim, 1e-6f);
        CHECK_CUDA(cudaMemsetAsync(moe_out, 0, dim * sizeof(float)));

        fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(h_in, norm, dim);
        __half* router_logits = h_out;
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N,
            cfg.n_experts, 1, dim, &alpha_h,
            mw.router_w, dim, h_in, dim,
            &beta_h, router_logits, cfg.n_experts);
        softmax_topk_kernel<<<1, 1>>>(d_expert_ids, d_expert_weights, router_logits, cfg.n_experts, topk);

        int h_ids[16]; float h_wts[16];
        CHECK_CUDA(cudaMemcpy(h_ids, d_expert_ids, topk * sizeof(int), cudaMemcpyDeviceToHost));
        CHECK_CUDA(cudaMemcpy(h_wts, d_expert_weights, topk * sizeof(float), cudaMemcpyDeviceToHost));

        // CPU-side gather: pack TopK experts into contiguous pinned staging
        for (int ki = 0; ki < topk; ki++) {
            int e = h_ids[ki];
            if (e < 0) e = 0;
            memcpy(h_pin_gate + ki * gate_q4_per_expert,
                   h_exp_gate[l] + (size_t)e * gate_q4_per_expert, gate_q4_per_expert);
            memcpy(h_pin_up + ki * up_q4_per_expert,
                   h_exp_up[l] + (size_t)e * up_q4_per_expert, up_q4_per_expert);
            memcpy(h_pin_down + ki * down_q4_per_expert,
                   h_exp_down[l] + (size_t)e * down_q4_per_expert, down_q4_per_expert);
        }

        // 3 bulk transfers: pinned CPU → GPU (instead of 24 small ones)
        size_t gate_batch = topk * gate_q4_per_expert;
        size_t up_batch   = topk * up_q4_per_expert;
        size_t down_batch = topk * down_q4_per_expert;
        CHECK_CUDA(cudaMemcpy(d_q4_gate_batch, h_pin_gate, gate_batch, cudaMemcpyHostToDevice));
        CHECK_CUDA(cudaMemcpy(d_q4_up_batch,   h_pin_up,   up_batch,   cudaMemcpyHostToDevice));
        CHECK_CUDA(cudaMemcpy(d_q4_down_batch,  h_pin_down,  down_batch, cudaMemcpyHostToDevice));

        // Write sequential indices [0..topk-1] for dequant (batch buffer is packed)
        int seq_ids[16];
        for (int ki = 0; ki < topk; ki++) seq_ids[ki] = ki;
        CHECK_CUDA(cudaMemcpy(d_expert_ids, seq_ids, topk * sizeof(int), cudaMemcpyHostToDevice));

        // Batched dequant all TopK experts at once
        dequant_topk_experts_q4_fp16<<<(topk * eff * (dim>>5) + 255)/256, 256>>>(
            expert_gate_fp16, d_q4_gate_batch, d_expert_ids, topk, eff, dim);
        dequant_topk_experts_q4_fp16<<<(topk * eff * (dim>>5) + 255)/256, 256>>>(
            expert_up_fp16, d_q4_up_batch, d_expert_ids, topk, eff, dim);
        dequant_topk_experts_q4_fp16<<<(topk * dim * (eff>>5) + 255)/256, 256>>>(
            expert_down_fp16, d_q4_down_batch, d_expert_ids, topk, dim, eff);

        // Strided batched HGEMM for all TopK experts
        long long strideA_gate = (long long)eff * dim;
        long long strideC_gate = (long long)eff;
        long long strideA_down = (long long)dim * eff;
        long long strideC_down = (long long)dim;

        CHECK_CUBLAS(cublasHgemmStridedBatched(handle,
            CUBLAS_OP_T, CUBLAS_OP_N, eff, 1, dim, &alpha_h,
            expert_gate_fp16, dim, strideA_gate, h_in, dim, 0, &beta_h,
            h_out, eff, strideC_gate, topk));

        __half* h_up_results = h_out + topk * eff;
        CHECK_CUBLAS(cublasHgemmStridedBatched(handle,
            CUBLAS_OP_T, CUBLAS_OP_N, eff, 1, dim, &alpha_h,
            expert_up_fp16, dim, strideA_gate, h_in, dim, 0, &beta_h,
            h_up_results, eff, strideC_gate, topk));

        fp16_swiglu_kernel<<<(topk*eff+255)/256, 256>>>(h_out, h_up_results, topk * eff);

        __half* h_down_results = h_up_results + topk * eff;
        CHECK_CUBLAS(cublasHgemmStridedBatched(handle,
            CUBLAS_OP_T, CUBLAS_OP_N, dim, 1, eff, &alpha_h,
            expert_down_fp16, eff, strideA_down,
            h_out, eff, (long long)eff, &beta_h,
            h_down_results, dim, strideC_down, topk));

        // Weighted scatter-add
        weighted_scatter_add_kernel<<<(dim+255)/256, 256>>>(
            moe_out, h_down_results, d_expert_weights, topk, dim);

        // Shared expert
        if (cfg.has_shared_expert && mw.shared_gate != nullptr) {
            __half* sg = h_down_results + topk*dim; __half* su = sg + eff; __half* sd = su + eff;
            cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, eff, 1, dim, &alpha_h, mw.shared_gate, dim, h_in, dim, &beta_h, sg, eff);
            cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, eff, 1, dim, &alpha_h, mw.shared_up, dim, h_in, dim, &beta_h, su, eff);
            fp16_swiglu_kernel<<<(eff+255)/256, 256>>>(sg, su, eff);
            cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, dim, 1, eff, &alpha_h, mw.shared_down, eff, sg, eff, &beta_h, sd, dim);
            fp16_to_fp32_kernel<<<(dim+255)/256, 256>>>(expert_out, sd, dim);
            vecadd_kernel<<<(dim+255)/256, 256>>>(moe_out, moe_out, expert_out, dim);
        }

        vecadd_kernel<<<(dim+255)/256, 256>>>(hidden, hidden, moe_out, dim);
    }

    rms_norm_kernel<<<1, 256, 256*sizeof(float)>>>(norm, hidden, d_rms_final, dim, 1e-6f);
    fp32_to_fp16_kernel<<<(dim+255)/256, 256>>>(h_in, norm, dim);
    cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, cfg.vocab, 1, dim,
                 &alpha_h, d_lm_head, dim, h_in, dim, &beta_h, h_out, cfg.vocab);
}

// ============================================================================
// Main: GGUF load + benchmark
// ============================================================================

int main(int argc, char** argv) {
    if (argc < 2) { printf("Usage: %s <model.gguf>\n", argv[0]); return 1; }

    // Memory-map GGUF file
    int fd = open(argv[1], O_RDONLY);
    struct stat st; fstat(fd, &st);
    size_t file_size = st.st_size;
    uint8_t* data = (uint8_t*)mmap(NULL, file_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);

    // Parse GGUF header
    uint32_t magic = read_u32(data);
    uint32_t version = read_u32(data + 4);
    uint64_t n_tensors = read_u64(data + 8);
    uint64_t n_kv = read_u64(data + 16);
    size_t kv_start = 24;

    printf("GGUF v%u: %llu tensors, %llu KV pairs\n", version, (unsigned long long)n_tensors, (unsigned long long)n_kv);

    // Parse MoE config
    MoEConfig cfg;
    cfg.dim = (int)find_int(data, kv_start, n_kv, "llama.embedding_length");
    if (cfg.dim <= 0) cfg.dim = (int)find_int(data, kv_start, n_kv, "qwen3moe.embedding_length");
    cfg.n_layers = (int)find_int(data, kv_start, n_kv, "llama.block_count");
    if (cfg.n_layers <= 0) cfg.n_layers = (int)find_int(data, kv_start, n_kv, "qwen3moe.block_count");
    cfg.n_heads = (int)find_int(data, kv_start, n_kv, "llama.attention.head_count");
    if (cfg.n_heads <= 0) cfg.n_heads = (int)find_int(data, kv_start, n_kv, "qwen3moe.attention.head_count");
    cfg.n_kv_heads = (int)find_int(data, kv_start, n_kv, "llama.attention.head_count_kv");
    if (cfg.n_kv_heads <= 0) cfg.n_kv_heads = (int)find_int(data, kv_start, n_kv, "qwen3moe.attention.head_count_kv");
    cfg.vocab = 0;  // detected from tensor
    cfg.rope_base = find_float(data, kv_start, n_kv, "llama.rope.freq_base");
    if (cfg.rope_base == 0.0f) cfg.rope_base = find_float(data, kv_start, n_kv, "qwen3moe.rope.freq_base");
    if (cfg.rope_base == 0.0f) cfg.rope_base = 10000.0f;

    // MoE-specific params
    cfg.n_experts = (int)find_int(data, kv_start, n_kv, "llama.expert_count");
    if (cfg.n_experts <= 0) cfg.n_experts = (int)find_int(data, kv_start, n_kv, "qwen3moe.expert_count");
    cfg.n_experts_topk = (int)find_int(data, kv_start, n_kv, "llama.expert_used_count");
    if (cfg.n_experts_topk <= 0) cfg.n_experts_topk = (int)find_int(data, kv_start, n_kv, "qwen3moe.expert_used_count");
    cfg.expert_ff = (int)find_int(data, kv_start, n_kv, "llama.expert_feed_forward_length");
    if (cfg.expert_ff <= 0) cfg.expert_ff = (int)find_int(data, kv_start, n_kv, "qwen3moe.expert_feed_forward_length");
    // Fallback: try standard feed_forward_length
    if (cfg.expert_ff <= 0) {
        cfg.expert_ff = (int)find_int(data, kv_start, n_kv, "llama.feed_forward_length");
        if (cfg.expert_ff <= 0) cfg.expert_ff = (int)find_int(data, kv_start, n_kv, "qwen3moe.feed_forward_length");
    }

    // Detect shared expert
    cfg.has_shared_expert = 0;
    int64_t shared_count = find_int(data, kv_start, n_kv, "llama.expert_shared_count");
    if (shared_count <= 0) shared_count = find_int(data, kv_start, n_kv, "qwen3moe.expert_shared_count");
    if (shared_count > 0) cfg.has_shared_expert = 1;

    printf("MoE Config: dim=%d layers=%d heads=%d kv_heads=%d\n",
           cfg.dim, cfg.n_layers, cfg.n_heads, cfg.n_kv_heads);
    printf("  experts=%d topk=%d expert_ff=%d shared=%d rope=%.0f\n",
           cfg.n_experts, cfg.n_experts_topk, cfg.expert_ff, cfg.has_shared_expert, cfg.rope_base);

    if (cfg.n_experts <= 0 || cfg.n_experts_topk <= 0) {
        printf("ERROR: Not a MoE model (no expert_count found in GGUF metadata)\n");
        printf("This benchmark requires a MoE model like Qwen3-30B-A3B-REAM\n");
        return 1;
    }

    int head_dim = cfg.dim / cfg.n_heads;
    int kv_dim = cfg.n_kv_heads * head_dim;

    // Skip KV pairs to tensor descriptors
    size_t pos = kv_start;
    for (uint64_t i = 0; i < n_kv; i++) pos = skip_gguf_kv(data, pos);

    // Build tensor name → (offset, type, dims) map
    struct TensorInfo { size_t data_offset; uint32_t dtype; uint64_t dims[4]; int n_dims; };
    TensorInfo* tensors = new TensorInfo[n_tensors];
    char** tensor_names = new char*[n_tensors];

    size_t tensor_desc_start = pos;
    for (uint64_t t = 0; t < n_tensors; t++) {
        uint64_t nl = read_u64(data + pos); pos += 8;
        tensor_names[t] = new char[nl + 1];
        memcpy(tensor_names[t], data + pos, nl);
        tensor_names[t][nl] = 0;
        pos += nl;
        tensors[t].n_dims = (int)read_u32(data + pos); pos += 4;
        for (int d = 0; d < tensors[t].n_dims; d++) {
            tensors[t].dims[d] = read_u64(data + pos); pos += 8;
        }
        tensors[t].dtype = read_u32(data + pos); pos += 4;
        tensors[t].data_offset = read_u64(data + pos); pos += 8;
    }

    // Compute tensor data base (aligned to 64 bytes)
    size_t tensor_data_base = (pos + 63) & ~(size_t)63;

    // Detect vocab from token_embd
    for (uint64_t t = 0; t < n_tensors; t++) {
        if (strcmp(tensor_names[t], "token_embd.weight") == 0) {
            cfg.vocab = (int)tensors[t].dims[1];
            break;
        }
    }
    printf("Vocab: %d\n", cfg.vocab);

    // Helper: find tensor by name
    auto find_tensor = [&](const char* name) -> int {
        for (uint64_t t = 0; t < n_tensors; t++)
            if (strcmp(tensor_names[t], name) == 0) return (int)t;
        return -1;
    };

    auto tensor_ptr = [&](int t) -> const uint8_t* {
        return data + tensor_data_base + tensors[t].data_offset;
    };

    // Helper: load Q4_0 tensor → FP16 on GPU
    auto load_q4_fp16 = [&](const char* name, int M, int K) -> __half* {
        int t = find_tensor(name);
        if (t < 0) { printf("WARNING: tensor '%s' not found\n", name); return nullptr; }
        if (tensors[t].dtype != 2) { printf("WARNING: '%s' type=%u, expected Q4_0(2)\n", name, tensors[t].dtype); return nullptr; }
        size_t q4_bytes = (size_t)M * (K / 32) * 18;
        uint8_t* d_q4; __half* d_fp16;
        CHECK_CUDA(cudaMalloc(&d_q4, q4_bytes));
        CHECK_CUDA(cudaMemcpy(d_q4, tensor_ptr(t), q4_bytes, cudaMemcpyHostToDevice));
        CHECK_CUDA(cudaMalloc(&d_fp16, (size_t)M * K * sizeof(__half)));
        int blocks = (M * (K >> 5) + 255) / 256;
        dequant_q4_fp16<<<blocks, 256>>>(d_fp16, d_q4, M, K);
        cudaDeviceSynchronize();
        cudaFree(d_q4);
        return d_fp16;
    };

    // Load F32 tensor
    auto load_f32 = [&](const char* name, int n) -> float* {
        int t = find_tensor(name);
        if (t < 0) return nullptr;
        float* d_ptr;
        CHECK_CUDA(cudaMalloc(&d_ptr, n * sizeof(float)));
        CHECK_CUDA(cudaMemcpy(d_ptr, tensor_ptr(t), n * sizeof(float), cudaMemcpyHostToDevice));
        return d_ptr;
    };

    // Load Q4_0 tensor raw (keep as Q4 on GPU)
    auto load_q4_raw = [&](const char* name, size_t bytes) -> uint8_t* {
        int t = find_tensor(name);
        if (t < 0) { printf("WARNING: tensor '%s' not found\n", name); return nullptr; }
        uint8_t* d_q4;
        CHECK_CUDA(cudaMalloc(&d_q4, bytes));
        CHECK_CUDA(cudaMemcpy(d_q4, tensor_ptr(t), bytes, cudaMemcpyHostToDevice));
        return d_q4;
    };

    // Load F16 tensor raw
    auto load_f16 = [&](const char* name, int n) -> __half* {
        int t = find_tensor(name);
        if (t < 0) return nullptr;
        __half* d_ptr;
        CHECK_CUDA(cudaMalloc(&d_ptr, n * sizeof(__half)));
        if (tensors[t].dtype == 1) {  // F16
            CHECK_CUDA(cudaMemcpy(d_ptr, tensor_ptr(t), n * sizeof(__half), cudaMemcpyHostToDevice));
        } else if (tensors[t].dtype == 0) {  // F32 → F16
            float* d_f32;
            CHECK_CUDA(cudaMalloc(&d_f32, n * sizeof(float)));
            CHECK_CUDA(cudaMemcpy(d_f32, tensor_ptr(t), n * sizeof(float), cudaMemcpyHostToDevice));
            fp32_to_fp16_kernel<<<(n+255)/256, 256>>>(d_ptr, d_f32, n);
            cudaDeviceSynchronize();
            cudaFree(d_f32);
        }
        return d_ptr;
    };

    // Host pointer helper (for expert offloading)
    auto host_ptr = [&](const char* name) -> const uint8_t* {
        int t = find_tensor(name);
        return t >= 0 ? tensor_ptr(t) : nullptr;
    };

    // CPU mmap pointers for expert offloading (per layer)
    const uint8_t* h_exp_gate[48] = {};
    const uint8_t* h_exp_up[48] = {};
    const uint8_t* h_exp_down[48] = {};

    printf("Loading MoE model weights...\n");

    // Embeddings + output
    __half* d_embd = load_q4_fp16("token_embd.weight", cfg.vocab, cfg.dim);
    if (!d_embd) d_embd = load_f16("token_embd.weight", cfg.vocab * cfg.dim);
    float* d_rms_final = load_f32("output_norm.weight", cfg.dim);
    __half* d_lm_head;
    int lm_t = find_tensor("output.weight");
    if (lm_t >= 0 && tensors[lm_t].dtype == 2) {
        d_lm_head = load_q4_fp16("output.weight", cfg.vocab, cfg.dim);
    } else if (lm_t >= 0) {
        d_lm_head = load_f16("output.weight", cfg.vocab * cfg.dim);
    } else {
        printf("output.weight not found, using tied embedding\n");
        d_lm_head = d_embd;
    }

    // Per-layer weights
    AttnWeights* attn_layers = new AttnWeights[cfg.n_layers];
    MoEFFNWeights* moe_layers = new MoEFFNWeights[cfg.n_layers];

    size_t expert_gate_q4_bytes = (size_t)cfg.n_experts * cfg.expert_ff * (cfg.dim / 32) * 18;
    size_t expert_up_q4_bytes = expert_gate_q4_bytes;
    size_t expert_down_q4_bytes = (size_t)cfg.n_experts * cfg.dim * (cfg.expert_ff / 32) * 18;

    for (int l = 0; l < cfg.n_layers; l++) {
        char name[128];
        // Attention weights (Q4→FP16)
        snprintf(name, sizeof(name), "blk.%d.attn_q.weight", l);
        attn_layers[l].wq = load_q4_fp16(name, cfg.dim, cfg.dim);
        snprintf(name, sizeof(name), "blk.%d.attn_k.weight", l);
        attn_layers[l].wk = load_q4_fp16(name, kv_dim, cfg.dim);
        snprintf(name, sizeof(name), "blk.%d.attn_v.weight", l);
        attn_layers[l].wv = load_q4_fp16(name, kv_dim, cfg.dim);
        snprintf(name, sizeof(name), "blk.%d.attn_output.weight", l);
        attn_layers[l].wo = load_q4_fp16(name, cfg.dim, cfg.dim);

        // Norms
        snprintf(name, sizeof(name), "blk.%d.attn_norm.weight", l);
        attn_layers[l].rms_attn = load_f32(name, cfg.dim);
        snprintf(name, sizeof(name), "blk.%d.ffn_norm.weight", l);
        attn_layers[l].rms_ffn = load_f32(name, cfg.dim);

        // Router
        snprintf(name, sizeof(name), "blk.%d.ffn_gate_inp.weight", l);
        moe_layers[l].router_w = load_f16(name, cfg.n_experts * cfg.dim);

        // Shared expert (Q4→FP16)
        if (cfg.has_shared_expert) {
            snprintf(name, sizeof(name), "blk.%d.ffn_gate_shexp.weight", l);
            moe_layers[l].shared_gate = load_q4_fp16(name, cfg.expert_ff, cfg.dim);
            snprintf(name, sizeof(name), "blk.%d.ffn_up_shexp.weight", l);
            moe_layers[l].shared_up = load_q4_fp16(name, cfg.expert_ff, cfg.dim);
            snprintf(name, sizeof(name), "blk.%d.ffn_down_shexp.weight", l);
            moe_layers[l].shared_down = load_q4_fp16(name, cfg.dim, cfg.expert_ff);
        } else {
            moe_layers[l].shared_gate = moe_layers[l].shared_up = moe_layers[l].shared_down = nullptr;
        }

        // Routed expert weights (Q4_0 raw on GPU + CPU mmap pointers for offloading)
        snprintf(name, sizeof(name), "blk.%d.ffn_gate_exps.weight", l);
        moe_layers[l].experts_gate_q4 = load_q4_raw(name, expert_gate_q4_bytes);
        h_exp_gate[l] = host_ptr(name);
        snprintf(name, sizeof(name), "blk.%d.ffn_up_exps.weight", l);
        moe_layers[l].experts_up_q4 = load_q4_raw(name, expert_up_q4_bytes);
        h_exp_up[l] = host_ptr(name);
        snprintf(name, sizeof(name), "blk.%d.ffn_down_exps.weight", l);
        moe_layers[l].experts_down_q4 = load_q4_raw(name, expert_down_q4_bytes);
        h_exp_down[l] = host_ptr(name);

        if (l == 0 || l == cfg.n_layers - 1)
            printf("  Layer %d loaded\n", l);
    }

    // VRAM stats
    size_t free_mem, total_mem;
    cudaMemGetInfo(&free_mem, &total_mem);
    printf("VRAM after weights: %.1f GB used, %.1f GB free\n",
           (total_mem - free_mem) / 1e9, free_mem / 1e9);

    // cuBLAS
    cublasHandle_t handle;
    CHECK_CUBLAS(cublasCreate(&handle));
    CHECK_CUBLAS(cublasSetMathMode(handle, CUBLAS_TENSOR_OP_MATH));

    // KV cache
    int MAX_SEQ = 128;
    FP16KVCache kv;
    init_fp16_kv(kv, cfg.n_layers, MAX_SEQ, kv_dim);
    printf("FP16 KV per user: %d MB (ctx=%d)\n",
           (int)(2LL * cfg.n_layers * MAX_SEQ * kv_dim * sizeof(__half) / (1024*1024)), MAX_SEQ);

    // Activation scratch buffers
    int MAX_K = 14;  // max DART draft tokens
    // Max unique experts in union: K × topk, capped at n_experts
    int MAX_UNION = cfg.n_experts_topk * MAX_K;
    if (MAX_UNION > cfg.n_experts) MAX_UNION = cfg.n_experts;
    if (MAX_UNION > 48) MAX_UNION = 48;  // cap for VRAM budget

    float *hidden, *norm, *q_buf, *k_buf, *v_buf, *attn_out, *moe_out, *expert_out;
    CHECK_CUDA(cudaMalloc(&hidden, (size_t)MAX_K * cfg.dim * sizeof(float)));
    CHECK_CUDA(cudaMalloc(&norm, cfg.dim * sizeof(float)));
    CHECK_CUDA(cudaMalloc(&q_buf, cfg.dim * sizeof(float)));
    CHECK_CUDA(cudaMalloc(&k_buf, kv_dim * sizeof(float)));
    CHECK_CUDA(cudaMalloc(&v_buf, kv_dim * sizeof(float)));
    CHECK_CUDA(cudaMalloc(&attn_out, cfg.dim * sizeof(float)));
    CHECK_CUDA(cudaMalloc(&moe_out, cfg.dim * sizeof(float)));
    CHECK_CUDA(cudaMalloc(&expert_out, cfg.dim * sizeof(float)));

    // FP16 scratch: need enough for HGEMM I/O + batched expert outputs
    __half *h_in, *h_out;
    CHECK_CUDA(cudaMalloc(&h_in, (size_t)cfg.dim * sizeof(__half)));
    // h_out needs: topk*eff (gate) + topk*eff (up) + topk*dim (down) + shared(2*eff+dim) + vocab
    size_t h_out_size = (size_t)cfg.n_experts_topk * cfg.expert_ff * 2
                      + (size_t)cfg.n_experts_topk * cfg.dim
                      + (size_t)cfg.expert_ff * 2 + cfg.dim
                      + (size_t)cfg.vocab;
    CHECK_CUDA(cudaMalloc(&h_out, h_out_size * sizeof(__half)));

    // Expert weight FP16 scratch (for union-set dequant: MAX_UNION experts stacked)
    __half *expert_gate_fp16, *expert_up_fp16, *expert_down_fp16;
    size_t expert_scratch = (size_t)MAX_UNION * cfg.expert_ff * cfg.dim * sizeof(__half);
    CHECK_CUDA(cudaMalloc(&expert_gate_fp16, expert_scratch));
    CHECK_CUDA(cudaMalloc(&expert_up_fp16, expert_scratch));
    CHECK_CUDA(cudaMalloc(&expert_down_fp16, expert_scratch));
    printf("Expert FP16 scratch: %.1f MB (max_union=%d)\n", 3.0f * expert_scratch / (1024*1024), MAX_UNION);

    // Router output buffers: K × topk slots for batch forward
    int *d_expert_ids;
    float *d_expert_weights;
    CHECK_CUDA(cudaMalloc(&d_expert_ids, MAX_K * cfg.n_experts_topk * sizeof(int)));
    CHECK_CUDA(cudaMalloc(&d_expert_weights, MAX_K * cfg.n_experts_topk * sizeof(float)));

    // Pre-allocated union ID buffer for batch forward
    int *d_union_ids;
    CHECK_CUDA(cudaMalloc(&d_union_ids, MAX_UNION * sizeof(int)));

    // Q4 staging buffers for expert offloading
    size_t gate_q4_per_expert = (size_t)cfg.expert_ff * (cfg.dim / 32) * 18;
    size_t down_q4_per_expert = (size_t)cfg.dim * (cfg.expert_ff / 32) * 18;
    size_t q4_staging_bytes = gate_q4_per_expert * 2 + down_q4_per_expert;  // gate+up+down
    uint8_t* d_q4_staging;
    CHECK_CUDA(cudaMalloc(&d_q4_staging, q4_staging_bytes));

    // Batched Q4 GPU staging (topk experts per matrix type)
    size_t q4_batch_gate = cfg.n_experts_topk * gate_q4_per_expert;
    size_t q4_batch_down = cfg.n_experts_topk * down_q4_per_expert;
    uint8_t *d_q4_gate_batch, *d_q4_up_batch, *d_q4_down_batch;
    CHECK_CUDA(cudaMalloc(&d_q4_gate_batch, q4_batch_gate));
    CHECK_CUDA(cudaMalloc(&d_q4_up_batch, q4_batch_gate));
    CHECK_CUDA(cudaMalloc(&d_q4_down_batch, q4_batch_down));

    // Pinned CPU staging for batched offload (topk experts packed)
    uint8_t *h_pin_gate, *h_pin_up, *h_pin_down;
    CHECK_CUDA(cudaHostAlloc(&h_pin_gate, q4_batch_gate, cudaHostAllocDefault));
    CHECK_CUDA(cudaHostAlloc(&h_pin_up, q4_batch_gate, cudaHostAllocDefault));
    CHECK_CUDA(cudaHostAlloc(&h_pin_down, q4_batch_down, cudaHostAllocDefault));
    printf("Q4 staging: %.1f MB (v1), %.1f MB pinned+GPU (v2 batched)\n",
           q4_staging_bytes / (1024.0f * 1024.0f),
           (q4_batch_gate * 2 + q4_batch_down) * 2 / (1024.0f * 1024.0f));

    cudaMemGetInfo(&free_mem, &total_mem);
    printf("VRAM after alloc: %.1f GB used, %.1f GB free\n",
           (total_mem - free_mem) / 1e9, free_mem / 1e9);

    // Pin mmap'd data for DMA transfers (expert offloading V3)
    printf("Attempting mlock + cudaHostRegister on mmap'd data (%.1f GB)...\n", file_size / 1e9);
    int mlock_ok = (mlock(data, file_size) == 0);
    int cuhr_ok = 0;
    if (mlock_ok) {
        cudaError_t e = cudaHostRegister(data, file_size, cudaHostRegisterPortable | cudaHostRegisterReadOnly);
        cuhr_ok = (e == cudaSuccess);
        if (!cuhr_ok) printf("  cudaHostRegister failed: %s (will use pageable path)\n", cudaGetErrorString(e));
    } else {
        printf("  mlock failed: %s (will use pageable path)\n", strerror(errno));
    }
    printf("  mlock=%s cudaHostRegister=%s\n", mlock_ok ? "OK" : "FAIL", cuhr_ok ? "OK" : "FAIL");

    // Prefill with a short prompt
    printf("\nPrefilling with 6-token prompt...\n");
    int prompt[] = {1, 4813, 338, 278, 1900, 310};
    for (int i = 0; i < 6; i++) {
        forward_moe_single(handle, cfg, attn_layers, moe_layers,
                           d_embd, d_lm_head, d_rms_final,
                           hidden, norm, q_buf, k_buf, v_buf, attn_out, moe_out,
                           h_in, h_out,
                           expert_gate_fp16, expert_up_fp16, expert_down_fp16,
                           expert_out, d_expert_ids, d_expert_weights,
                           kv, prompt[i], i);
    }
    cudaDeviceSynchronize();

    // Download top logit to verify
    float top_logit = -1e30f;
    int top_token = 0;
    {
        // h_out has FP16 logits from final HGEMM
        __half* logits_fp16 = (__half*)malloc(cfg.vocab * sizeof(__half));
        CHECK_CUDA(cudaMemcpy(logits_fp16, h_out, cfg.vocab * sizeof(__half), cudaMemcpyDeviceToHost));
        for (int i = 0; i < cfg.vocab; i++) {
            float v = __half2float(logits_fp16[i]);
            if (v > top_logit) { top_logit = v; top_token = i; }
        }
        free(logits_fp16);
    }
    printf("Top token: %d (logit=%.2f)\n", top_token, top_logit);

    // Benchmark: single-token latency
    printf("\n=== MoE Single-Token Baseline ===\n");
    int warmup = 3, iters = 10;
    for (int i = 0; i < warmup; i++) {
        forward_moe_single(handle, cfg, attn_layers, moe_layers,
                           d_embd, d_lm_head, d_rms_final,
                           hidden, norm, q_buf, k_buf, v_buf, attn_out, moe_out,
                           h_in, h_out,
                           expert_gate_fp16, expert_up_fp16, expert_down_fp16,
                           expert_out, d_expert_ids, d_expert_weights,
                           kv, prompt[0], 6);
    }
    cudaDeviceSynchronize();

    cudaEvent_t t_start, t_end;
    cudaEventCreate(&t_start); cudaEventCreate(&t_end);
    cudaEventRecord(t_start);
    for (int i = 0; i < iters; i++) {
        forward_moe_single(handle, cfg, attn_layers, moe_layers,
                           d_embd, d_lm_head, d_rms_final,
                           hidden, norm, q_buf, k_buf, v_buf, attn_out, moe_out,
                           h_in, h_out,
                           expert_gate_fp16, expert_up_fp16, expert_down_fp16,
                           expert_out, d_expert_ids, d_expert_weights,
                           kv, prompt[0], 6);
    }
    cudaEventRecord(t_end);
    cudaEventSynchronize(t_end);
    float ms = 0;
    cudaEventElapsedTime(&ms, t_start, t_end);
    float avg_ms = ms / iters;
    float cold_ms = avg_ms;  // save for comparison
    printf("Single-token (MoE, FP16 KV): %.1f ms → %.1f TPS\n", avg_ms, 1000.0f / avg_ms);
    printf("  Active params per token: %d experts × %d params = %.1f M active\n",
           cfg.n_experts_topk, 3 * cfg.expert_ff * cfg.dim,
           (float)cfg.n_experts_topk * 3 * cfg.expert_ff * cfg.dim / 1e6);

    // Warm-cache benchmark: skip dequant (simulates perfect expert FP16 cache)
    printf("\n=== MoE Warm-Cache (skip dequant, simulates FP16 expert cache) ===\n");
    // First run WITH dequant to populate the FP16 scratch buffers
    forward_moe_single(handle, cfg, attn_layers, moe_layers,
                       d_embd, d_lm_head, d_rms_final,
                       hidden, norm, q_buf, k_buf, v_buf, attn_out, moe_out,
                       h_in, h_out,
                       expert_gate_fp16, expert_up_fp16, expert_down_fp16,
                       expert_out, d_expert_ids, d_expert_weights,
                       kv, prompt[0], 6, false);
    cudaDeviceSynchronize();
    // Now benchmark with skip_dequant=true (FP16 weights already in scratch)
    for (int i = 0; i < warmup; i++) {
        forward_moe_single(handle, cfg, attn_layers, moe_layers,
                           d_embd, d_lm_head, d_rms_final,
                           hidden, norm, q_buf, k_buf, v_buf, attn_out, moe_out,
                           h_in, h_out,
                           expert_gate_fp16, expert_up_fp16, expert_down_fp16,
                           expert_out, d_expert_ids, d_expert_weights,
                           kv, prompt[0], 6, true);
    }
    cudaDeviceSynchronize();
    cudaEventRecord(t_start);
    for (int i = 0; i < iters; i++) {
        forward_moe_single(handle, cfg, attn_layers, moe_layers,
                           d_embd, d_lm_head, d_rms_final,
                           hidden, norm, q_buf, k_buf, v_buf, attn_out, moe_out,
                           h_in, h_out,
                           expert_gate_fp16, expert_up_fp16, expert_down_fp16,
                           expert_out, d_expert_ids, d_expert_weights,
                           kv, prompt[0], 6, true);
    }
    cudaEventRecord(t_end);
    cudaEventSynchronize(t_end);
    cudaEventElapsedTime(&ms, t_start, t_end);
    avg_ms = ms / iters;
    float warm_ms = avg_ms;
    printf("Warm-cache (no dequant): %.1f ms → %.1f TPS\n", warm_ms, 1000.0f / warm_ms);
    printf("  Speedup vs cold: %.2fx (dequant overhead: %.1f ms = %.0f%%)\n",
           cold_ms / warm_ms, cold_ms - warm_ms, (cold_ms - warm_ms) / cold_ms * 100.0f);

    // ============================================================================
    // DART Batch Sweep: K draft tokens with union-dequant amortization
    // ============================================================================
    printf("\n=== MoE DART Batch Forward (union-dequant amortization) ===\n");
    printf("%-4s %-10s %-8s", "K", "Batch ms", "ms/tok");
    float alphas[] = {0.7f, 0.85f, 0.9f, 0.95f};
    int n_alphas = 4;
    for (int a = 0; a < n_alphas; a++) printf("  α=%.2f TPS", alphas[a]);
    printf("\n");

    int K_values[] = {1, 4, 8, 12};
    int n_K = 4;
    int batch_warmup = 2, batch_iters = 5;

    for (int ki = 0; ki < n_K; ki++) {
        int K = K_values[ki];
        if (K > MAX_K) continue;

        // Create K draft tokens (reuse prompt tokens, wrapping)
        int draft_tokens[16];
        for (int t = 0; t < K; t++) draft_tokens[t] = prompt[t % 6];

        // Warmup
        for (int i = 0; i < batch_warmup; i++) {
            forward_moe_batch(handle, cfg, attn_layers, moe_layers,
                d_embd, d_lm_head, d_rms_final,
                hidden, norm, q_buf, k_buf, v_buf, attn_out, moe_out,
                h_in, h_out,
                expert_gate_fp16, expert_up_fp16, expert_down_fp16,
                expert_out, d_expert_ids, d_expert_weights, d_union_ids,
                kv, draft_tokens, K, 6);
        }
        cudaDeviceSynchronize();

        // Timed runs
        cudaEventRecord(t_start);
        for (int i = 0; i < batch_iters; i++) {
            forward_moe_batch(handle, cfg, attn_layers, moe_layers,
                d_embd, d_lm_head, d_rms_final,
                hidden, norm, q_buf, k_buf, v_buf, attn_out, moe_out,
                h_in, h_out,
                expert_gate_fp16, expert_up_fp16, expert_down_fp16,
                expert_out, d_expert_ids, d_expert_weights, d_union_ids,
                kv, draft_tokens, K, 6);
        }
        cudaEventRecord(t_end);
        cudaEventSynchronize(t_end);
        cudaEventElapsedTime(&ms, t_start, t_end);
        float batch_ms = ms / batch_iters;
        float per_tok = batch_ms / K;

        printf("%-4d %-10.1f %-8.1f", K, batch_ms, per_tok);
        for (int a = 0; a < n_alphas; a++) {
            // DART effective TPS: accepted_tokens / batch_time
            // Expected accepted = 1 + α + α² + ... + α^(K-1) = (1 - α^K) / (1 - α)
            float alpha = alphas[a];
            float expected_accepted = (1.0f - powf(alpha, (float)K)) / (1.0f - alpha);
            float eff_tps = expected_accepted / (batch_ms / 1000.0f);
            printf("  %8.1f", eff_tps);
        }
        printf("\n");
    }

    printf("\nTarget: 133 TPS per-user (TinyLlama 1.1B baseline)\n");

    // ============================================================================
    // Expert Offloading Benchmark: experts in CPU mmap, transfer per layer
    // ============================================================================
    printf("\n=== Expert Offloading (CPU → GPU per layer) ===\n");

    // Report expert weight stats
    size_t expert_vram_per_layer = expert_gate_q4_bytes + expert_up_q4_bytes + expert_down_q4_bytes;
    float expert_vram_total_gb = (float)expert_vram_per_layer * cfg.n_layers / 1e9;
    float per_expert_mb = (gate_q4_per_expert * 2 + down_q4_per_expert) / (1024.0f * 1024.0f);
    printf("Expert weights: %.1f GB in VRAM (%.1f MB per expert Q4)\n",
           expert_vram_total_gb, per_expert_mb);
    printf("TopK=%d → %.1f MB transferred per layer, %.1f MB per forward\n",
           cfg.n_experts_topk,
           per_expert_mb * cfg.n_experts_topk,
           per_expert_mb * cfg.n_experts_topk * cfg.n_layers);

    // Reset KV cache for offload benchmark
    kv.seq_len = 0;
    for (int i = 0; i < 6; i++) {
        forward_moe_offload(handle, cfg, attn_layers, moe_layers,
            h_exp_gate, h_exp_up, h_exp_down, d_q4_staging,
            d_embd, d_lm_head, d_rms_final,
            hidden, norm, q_buf, k_buf, v_buf, attn_out, moe_out,
            h_in, h_out,
            expert_gate_fp16, expert_up_fp16, expert_down_fp16,
            expert_out, d_expert_ids, d_expert_weights,
            kv, prompt[i], i);
        kv.seq_len = i + 1;
    }
    cudaDeviceSynchronize();

    // Warmup offload forward
    for (int i = 0; i < warmup; i++) {
        forward_moe_offload(handle, cfg, attn_layers, moe_layers,
            h_exp_gate, h_exp_up, h_exp_down, d_q4_staging,
            d_embd, d_lm_head, d_rms_final,
            hidden, norm, q_buf, k_buf, v_buf, attn_out, moe_out,
            h_in, h_out,
            expert_gate_fp16, expert_up_fp16, expert_down_fp16,
            expert_out, d_expert_ids, d_expert_weights,
            kv, prompt[0], 6);
    }
    cudaDeviceSynchronize();

    // Timed offload runs
    cudaEventRecord(t_start);
    for (int i = 0; i < iters; i++) {
        forward_moe_offload(handle, cfg, attn_layers, moe_layers,
            h_exp_gate, h_exp_up, h_exp_down, d_q4_staging,
            d_embd, d_lm_head, d_rms_final,
            hidden, norm, q_buf, k_buf, v_buf, attn_out, moe_out,
            h_in, h_out,
            expert_gate_fp16, expert_up_fp16, expert_down_fp16,
            expert_out, d_expert_ids, d_expert_weights,
            kv, prompt[0], 6);
    }
    cudaEventRecord(t_end);
    cudaEventSynchronize(t_end);
    cudaEventElapsedTime(&ms, t_start, t_end);
    float offload_ms = ms / iters;
    printf("Offload forward: %.1f ms → %.1f TPS\n", offload_ms, 1000.0f / offload_ms);
    printf("  vs On-GPU cold: %.2fx slower (%.1f ms overhead)\n",
           offload_ms / cold_ms, offload_ms - cold_ms);
    printf("  vs On-GPU warm: %.2fx slower\n", offload_ms / warm_ms);

    // Report VRAM savings if experts were fully offloaded
    printf("\n  VRAM savings if experts offloaded:\n");
    printf("    Current expert VRAM: %.1f GB\n", expert_vram_total_gb);
    printf("    Freed for KV caches: %.0f users × ctx=2048 (%.0f MB/user)\n",
           expert_vram_total_gb * 1e3 / (cfg.n_layers * 2 * 128 * kv_dim * 2.0f / (1024*1024) * (2048.0f/128)),
           cfg.n_layers * 2.0f * 2048 * kv_dim * 2.0f / (1024*1024));

    // Simpler VRAM math
    float kv_per_user_mb = cfg.n_layers * 2.0f * 2048 * kv_dim * sizeof(__half) / (1024.0f * 1024.0f);
    int max_users_offloaded = (int)(expert_vram_total_gb * 1024.0f / kv_per_user_mb);
    printf("    KV per user (ctx=2048): %.0f MB → %d concurrent users possible\n",
           kv_per_user_mb, max_users_offloaded);

    // ---- V2: Pinned + batched offload (3 transfers/layer) ----
    printf("\n--- V2: Pinned staging + batched transfer (3 calls/layer) ---\n");

    kv.seq_len = 0;
    for (int i = 0; i < 6; i++) {
        forward_moe_offload_pinned(handle, cfg, attn_layers, moe_layers,
            h_exp_gate, h_exp_up, h_exp_down,
            h_pin_gate, h_pin_up, h_pin_down,
            d_q4_gate_batch, d_q4_up_batch, d_q4_down_batch,
            d_embd, d_lm_head, d_rms_final,
            hidden, norm, q_buf, k_buf, v_buf, attn_out, moe_out,
            h_in, h_out,
            expert_gate_fp16, expert_up_fp16, expert_down_fp16,
            expert_out, d_expert_ids, d_expert_weights,
            kv, prompt[i], i);
        kv.seq_len = i + 1;
    }
    cudaDeviceSynchronize();

    for (int i = 0; i < warmup; i++) {
        forward_moe_offload_pinned(handle, cfg, attn_layers, moe_layers,
            h_exp_gate, h_exp_up, h_exp_down,
            h_pin_gate, h_pin_up, h_pin_down,
            d_q4_gate_batch, d_q4_up_batch, d_q4_down_batch,
            d_embd, d_lm_head, d_rms_final,
            hidden, norm, q_buf, k_buf, v_buf, attn_out, moe_out,
            h_in, h_out,
            expert_gate_fp16, expert_up_fp16, expert_down_fp16,
            expert_out, d_expert_ids, d_expert_weights,
            kv, prompt[0], 6);
    }
    cudaDeviceSynchronize();

    cudaEventRecord(t_start);
    for (int i = 0; i < iters; i++) {
        forward_moe_offload_pinned(handle, cfg, attn_layers, moe_layers,
            h_exp_gate, h_exp_up, h_exp_down,
            h_pin_gate, h_pin_up, h_pin_down,
            d_q4_gate_batch, d_q4_up_batch, d_q4_down_batch,
            d_embd, d_lm_head, d_rms_final,
            hidden, norm, q_buf, k_buf, v_buf, attn_out, moe_out,
            h_in, h_out,
            expert_gate_fp16, expert_up_fp16, expert_down_fp16,
            expert_out, d_expert_ids, d_expert_weights,
            kv, prompt[0], 6);
    }
    cudaEventRecord(t_end);
    cudaEventSynchronize(t_end);
    cudaEventElapsedTime(&ms, t_start, t_end);
    float pinned_ms = ms / iters;
    printf("Pinned offload: %.1f ms → %.1f TPS\n", pinned_ms, 1000.0f / pinned_ms);
    printf("  vs V1 naive: %.2fx speedup\n", offload_ms / pinned_ms);
    printf("  vs On-GPU cold: %.2fx slower\n", pinned_ms / cold_ms);
    printf("  vs On-GPU warm: %.2fx slower\n", pinned_ms / warm_ms);
    printf("  PCIe effective: %.1f GB/s (%.1f MB/fwd transferred)\n",
           per_expert_mb * cfg.n_experts_topk * cfg.n_layers / (pinned_ms / 1000.0f) / 1024.0f,
           per_expert_mb * cfg.n_experts_topk * cfg.n_layers);

    // ---- V3: Pre-fault mmap + measure transfer-only overhead ----
    {
        printf("\n--- V3: Transfer-only microbench (mmap pre-faulted) ---\n");
        // Pre-fault: read all expert weight pages into OS cache
        printf("  Pre-faulting expert weight pages...\n");
        volatile uint8_t sink = 0;
        for (int l = 0; l < cfg.n_layers; l++) {
            size_t exp_bytes = expert_gate_q4_bytes;
            // Touch every 4K page in gate/up/down
            for (size_t off = 0; off < exp_bytes; off += 4096)
                sink ^= h_exp_gate[l][off];
            for (size_t off = 0; off < exp_bytes; off += 4096)
                sink ^= h_exp_up[l][off];
            exp_bytes = expert_down_q4_bytes;
            for (size_t off = 0; off < exp_bytes; off += 4096)
                sink ^= h_exp_down[l][off];
        }
        (void)sink;

        // Microbench: just measure CPU gather + cudaMemcpy (no dequant/HGEMM)
        // This isolates the PCIe transfer cost
        int xfer_iters = 3;
        cudaDeviceSynchronize();
        cudaEventRecord(t_start);
        for (int it = 0; it < xfer_iters; it++) {
            for (int l = 0; l < cfg.n_layers; l++) {
                // Use fixed expert IDs 0..topk-1 for consistent measurement
                for (int ki = 0; ki < cfg.n_experts_topk; ki++) {
                    int e = ki;
                    memcpy(h_pin_gate + ki * gate_q4_per_expert,
                           h_exp_gate[l] + (size_t)e * gate_q4_per_expert, gate_q4_per_expert);
                    memcpy(h_pin_up + ki * gate_q4_per_expert,
                           h_exp_up[l] + (size_t)e * gate_q4_per_expert, gate_q4_per_expert);
                    memcpy(h_pin_down + ki * down_q4_per_expert,
                           h_exp_down[l] + (size_t)e * down_q4_per_expert, down_q4_per_expert);
                }
                CHECK_CUDA(cudaMemcpy(d_q4_gate_batch, h_pin_gate,
                    q4_batch_gate, cudaMemcpyHostToDevice));
                CHECK_CUDA(cudaMemcpy(d_q4_up_batch, h_pin_up,
                    q4_batch_gate, cudaMemcpyHostToDevice));
                CHECK_CUDA(cudaMemcpy(d_q4_down_batch, h_pin_down,
                    q4_batch_down, cudaMemcpyHostToDevice));
            }
        }
        cudaEventRecord(t_end);
        cudaEventSynchronize(t_end);
        cudaEventElapsedTime(&ms, t_start, t_end);
        float xfer_ms = ms / xfer_iters;
        printf("  Transfer-only (gather+memcpy): %.1f ms/forward\n", xfer_ms);
        printf("  PCIe effective: %.1f GB/s (%.1f MB transferred)\n",
               per_expert_mb * cfg.n_experts_topk * cfg.n_layers / (xfer_ms / 1000.0f) / 1024.0f,
               per_expert_mb * cfg.n_experts_topk * cfg.n_layers);
        printf("  Compute-only (warm): %.1f ms\n", warm_ms);
        printf("  Transfer/compute ratio: %.1f:1 (transfer dominates)\n", xfer_ms / warm_ms);
        printf("  Theoretical async pipeline: max(%.1f, %.1f) = %.1f ms → %.1f TPS\n",
               xfer_ms, warm_ms, fmaxf(xfer_ms, warm_ms),
               1000.0f / fmaxf(xfer_ms, warm_ms));

        // Re-run V2 with pre-faulted pages
        printf("\n  V2 with pre-faulted pages:\n");
        kv.seq_len = 0;
        for (int i = 0; i < 6; i++) {
            forward_moe_offload_pinned(handle, cfg, attn_layers, moe_layers,
                h_exp_gate, h_exp_up, h_exp_down,
                h_pin_gate, h_pin_up, h_pin_down,
                d_q4_gate_batch, d_q4_up_batch, d_q4_down_batch,
                d_embd, d_lm_head, d_rms_final,
                hidden, norm, q_buf, k_buf, v_buf, attn_out, moe_out,
                h_in, h_out,
                expert_gate_fp16, expert_up_fp16, expert_down_fp16,
                expert_out, d_expert_ids, d_expert_weights,
                kv, prompt[i], i);
            kv.seq_len = i + 1;
        }
        cudaDeviceSynchronize();

        for (int i = 0; i < warmup; i++) {
            forward_moe_offload_pinned(handle, cfg, attn_layers, moe_layers,
                h_exp_gate, h_exp_up, h_exp_down,
                h_pin_gate, h_pin_up, h_pin_down,
                d_q4_gate_batch, d_q4_up_batch, d_q4_down_batch,
                d_embd, d_lm_head, d_rms_final,
                hidden, norm, q_buf, k_buf, v_buf, attn_out, moe_out,
                h_in, h_out,
                expert_gate_fp16, expert_up_fp16, expert_down_fp16,
                expert_out, d_expert_ids, d_expert_weights,
                kv, prompt[0], 6);
        }
        cudaDeviceSynchronize();

        cudaEventRecord(t_start);
        for (int i = 0; i < iters; i++) {
            forward_moe_offload_pinned(handle, cfg, attn_layers, moe_layers,
                h_exp_gate, h_exp_up, h_exp_down,
                h_pin_gate, h_pin_up, h_pin_down,
                d_q4_gate_batch, d_q4_up_batch, d_q4_down_batch,
                d_embd, d_lm_head, d_rms_final,
                hidden, norm, q_buf, k_buf, v_buf, attn_out, moe_out,
                h_in, h_out,
                expert_gate_fp16, expert_up_fp16, expert_down_fp16,
                expert_out, d_expert_ids, d_expert_weights,
                kv, prompt[0], 6);
        }
        cudaEventRecord(t_end);
        cudaEventSynchronize(t_end);
        cudaEventElapsedTime(&ms, t_start, t_end);
        float faulted_ms = ms / iters;
        printf("  Pre-faulted V2: %.1f ms → %.1f TPS\n", faulted_ms, 1000.0f / faulted_ms);
        printf("  vs V2 cold-pages: %.2fx speedup\n", pinned_ms / faulted_ms);
        printf("  vs On-GPU cold: %.2fx slower\n", faulted_ms / cold_ms);
    }

    // Cleanup
    if (mlock_ok) munlock(data, file_size);
    cudaEventDestroy(t_start);
    cudaEventDestroy(t_end);
    cublasDestroy(handle);
    munmap(data, file_size);

    return 0;
}

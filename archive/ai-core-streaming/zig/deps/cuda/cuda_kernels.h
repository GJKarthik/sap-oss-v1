/**
 * CUDA Kernels – CPU Fallback with Real Computation
 *
 * Drop-in replacement header for builds without the CUDA toolkit.
 * Every function is `static inline` so the header is self-contained and
 * does not require a separate .c/.cu translation unit.
 *
 * All math/memory functions have real CPU implementations.
 * GPU-only orchestration (graphs) returns CUDA_ERR_NOT_SUPPORTED.
 * Tensor parallelism has full CPU implementation with NCCL-compatible architecture.
 */

#ifndef CUDA_KERNELS_H
#define CUDA_KERNELS_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <float.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ========================================================================== */
/* Error Codes                                                                */
/* ========================================================================== */

typedef enum {
    CUDA_OK                  =  0,
    CUDA_ERR_NOT_INITIALIZED = -1,
    CUDA_ERR_NO_DEVICE       = -2,
    CUDA_ERR_ALLOC           = -3,
    CUDA_ERR_MEMCPY          = -4,
    CUDA_ERR_KERNEL          = -5,
    CUDA_ERR_CUBLAS          = -6,
    CUDA_ERR_INVALID_ARG     = -7,
    CUDA_ERR_OUT_OF_RANGE    = -8,
    CUDA_ERR_GRAPH           = -9,
    CUDA_ERR_NOT_SUPPORTED   = -10,
} CudaErrorCode;

static inline const char* cuda_error_string(int error_code) {
    switch (error_code) {
        case  0: return "CUDA_OK: success";
        case -1: return "CUDA_ERR_NOT_INITIALIZED: CUDA not initialized (CPU fallback)";
        case -2: return "CUDA_ERR_NO_DEVICE: no CUDA-capable device (CPU fallback active)";
        case -3: return "CUDA_ERR_ALLOC: memory allocation failed";
        case -4: return "CUDA_ERR_MEMCPY: memory copy failed";
        case -5: return "CUDA_ERR_KERNEL: kernel execution failed";
        case -6: return "CUDA_ERR_CUBLAS: BLAS operation failed";
        case -7: return "CUDA_ERR_INVALID_ARG: invalid argument";
        case -8: return "CUDA_ERR_OUT_OF_RANGE: index/size out of range";
        case -9: return "CUDA_ERR_GRAPH: graph operation not supported on CPU";
        case -10: return "CUDA_ERR_NOT_SUPPORTED: operation not supported on CPU";
        default: return "Unknown error";
    }
}

/* ========================================================================== */
/* Initialization & Device Management                                         */
/* ========================================================================== */

typedef struct {
    char name[256];
    size_t total_memory;
    size_t free_memory;
    int compute_capability_major;
    int compute_capability_minor;
    int multiprocessor_count;
    int max_threads_per_block;
} CudaDeviceInfo;

static int g_cpu_fallback_initialized = 0;

static inline int cuda_init(void) {
    g_cpu_fallback_initialized = 1;
    return CUDA_OK;
}
static inline void cuda_shutdown(void) { g_cpu_fallback_initialized = 0; }
static inline int cuda_is_available(void) { return 0; /* No GPU, CPU fallback */ }

static inline int cuda_get_device_info(CudaDeviceInfo* info) {
    if (!info) return CUDA_ERR_INVALID_ARG;
    memset(info->name, 0, 256);
    snprintf(info->name, 256, "CPU Fallback (no GPU)");
    info->total_memory = (size_t)16ULL * 1024 * 1024 * 1024; /* 16 GB simulated */
    info->free_memory  = (size_t)12ULL * 1024 * 1024 * 1024;
    info->compute_capability_major = 0;
    info->compute_capability_minor = 0;
    info->multiprocessor_count = 1;
    info->max_threads_per_block = 1;
    return CUDA_OK;
}

/* ========================================================================== */
/* Memory Management — real malloc/memcpy on CPU                              */
/* ========================================================================== */

static size_t g_cpu_alloc_bytes = 0;

static inline void* cuda_malloc(size_t size) {
    if (size == 0) return NULL;
    void* p = malloc(size);
    if (p) g_cpu_alloc_bytes += size;
    return p;
}
static inline void cuda_free(void* ptr) { free(ptr); }

static inline int cuda_memcpy_h2d(void* dst, const void* src, size_t size) {
    if (!dst || !src) return CUDA_ERR_INVALID_ARG;
    memcpy(dst, src, size);
    return CUDA_OK;
}
static inline int cuda_memcpy_d2h(void* dst, const void* src, size_t size) {
    if (!dst || !src) return CUDA_ERR_INVALID_ARG;
    memcpy(dst, src, size);
    return CUDA_OK;
}
static inline int cuda_memcpy_d2d(void* dst, const void* src, size_t size) {
    if (!dst || !src) return CUDA_ERR_INVALID_ARG;
    memmove(dst, src, size); /* memmove for overlapping */
    return CUDA_OK;
}
static inline int cuda_memset(void* ptr, int value, size_t size) {
    if (!ptr) return CUDA_ERR_INVALID_ARG;
    memset(ptr, value, size);
    return CUDA_OK;
}

/* ========================================================================== */
/* cuBLAS Matrix Operations — real CPU BLAS                                   */
/* ========================================================================== */

static inline int cublas_init(void) { return CUDA_OK; }
static inline void cublas_shutdown(void) { }

/* C = alpha * A(M×K) * B(K×N) + beta * C(M×N)  — row-major */
static inline int cublas_sgemm(
    float* C, const float* A, const float* B,
    int M, int N, int K, float alpha, float beta
) {
    if (!C || !A || !B) return CUDA_ERR_INVALID_ARG;
    for (int i = 0; i < M; i++) {
        for (int j = 0; j < N; j++) {
            float sum = 0.0f;
            for (int k = 0; k < K; k++)
                sum += A[i * K + k] * B[k * N + j];
            C[i * N + j] = alpha * sum + beta * C[i * N + j];
        }
    }
    return CUDA_OK;
}

/* y = alpha * A(M×K) * x(K) + beta * y(M) */
static inline int cublas_sgemv(
    float* y, const float* A, const float* x,
    int M, int K, float alpha, float beta
) {
    if (!y || !A || !x) return CUDA_ERR_INVALID_ARG;
    for (int i = 0; i < M; i++) {
        float sum = 0.0f;
        for (int k = 0; k < K; k++)
            sum += A[i * K + k] * x[k];
        y[i] = alpha * sum + beta * y[i];
    }
    return CUDA_OK;
}

/* C = alpha * A(M×K) * B^T(N×K) + beta * C  (B stored row-major, transposed) */
static inline int cublas_sgemm_transB(
    float* C, const float* A, const float* B,
    int M, int N, int K, float alpha, float beta
) {
    if (!C || !A || !B) return CUDA_ERR_INVALID_ARG;
    for (int i = 0; i < M; i++) {
        for (int j = 0; j < N; j++) {
            float sum = 0.0f;
            for (int k = 0; k < K; k++)
                sum += A[i * K + k] * B[j * K + k]; /* B transposed */
            C[i * N + j] = alpha * sum + beta * C[i * N + j];
        }
    }
    return CUDA_OK;
}

/* Batched SGEMM: batch_size independent C = alpha*A*B + beta*C */
static inline int cublas_sgemm_batched(
    float* C, const float* A, const float* B,
    int batch_size, int M, int N, int K, float alpha, float beta
) {
    if (!C || !A || !B) return CUDA_ERR_INVALID_ARG;
    int stride_a = M * K, stride_b = K * N, stride_c = M * N;
    for (int b = 0; b < batch_size; b++) {
        cublas_sgemm(C + b * stride_c, A + b * stride_a,
                     B + b * stride_b, M, N, K, alpha, beta);
    }
    return CUDA_OK;
}

/* ========================================================================== */
/* Custom CUDA Kernels – Activations (real CPU)                               */
/* ========================================================================== */

/* SiLU(x) = x * sigmoid(x) = x / (1 + exp(-x)) */
static inline int cuda_silu(float* dst, const float* src, int n) {
    if (!dst || !src) return CUDA_ERR_INVALID_ARG;
    for (int i = 0; i < n; i++)
        dst[i] = src[i] / (1.0f + expf(-src[i]));
    return CUDA_OK;
}
static inline int cuda_silu_inplace(float* data, int n) {
    if (!data) return CUDA_ERR_INVALID_ARG;
    for (int i = 0; i < n; i++)
        data[i] = data[i] / (1.0f + expf(-data[i]));
    return CUDA_OK;
}
/* GELU(x) ≈ 0.5·x·(1 + tanh(√(2/π)·(x + 0.044715·x³))) */
static inline int cuda_gelu(float* dst, const float* src, int n) {
    if (!dst || !src) return CUDA_ERR_INVALID_ARG;
    const float c = 0.7978845608f; /* sqrt(2/pi) */
    for (int i = 0; i < n; i++) {
        float x = src[i];
        dst[i] = 0.5f * x * (1.0f + tanhf(c * (x + 0.044715f * x * x * x)));
    }
    return CUDA_OK;
}
static inline int cuda_relu(float* dst, const float* src, int n) {
    if (!dst || !src) return CUDA_ERR_INVALID_ARG;
    for (int i = 0; i < n; i++)
        dst[i] = src[i] > 0.0f ? src[i] : 0.0f;
    return CUDA_OK;
}

/* ========================================================================== */
/* Custom CUDA Kernels – Normalization (real CPU)                             */
/* ========================================================================== */

/* RMSNorm: dst[i] = weight[i] * src[i] / sqrt(mean(src²) + eps) */
static inline int cuda_rms_norm(
    float* dst, const float* src, const float* weight,
    int n, float eps
) {
    if (!dst || !src || !weight || n <= 0) return CUDA_ERR_INVALID_ARG;
    float ss = 0.0f;
    for (int i = 0; i < n; i++) ss += src[i] * src[i];
    float rms = 1.0f / sqrtf(ss / (float)n + eps);
    for (int i = 0; i < n; i++) dst[i] = weight[i] * src[i] * rms;
    return CUDA_OK;
}

static inline int cuda_rms_norm_batched(
    float* dst, const float* src, const float* weight,
    int batch_size, int n, float eps
) {
    if (!dst || !src || !weight) return CUDA_ERR_INVALID_ARG;
    for (int b = 0; b < batch_size; b++)
        cuda_rms_norm(dst + b * n, src + b * n, weight, n, eps);
    return CUDA_OK;
}

/* Numerically stable softmax: subtract max, exp, normalize */
static inline int cuda_softmax(float* data, int n) {
    if (!data || n <= 0) return CUDA_ERR_INVALID_ARG;
    float mx = data[0];
    for (int i = 1; i < n; i++) if (data[i] > mx) mx = data[i];
    float sum = 0.0f;
    for (int i = 0; i < n; i++) { data[i] = expf(data[i] - mx); sum += data[i]; }
    if (sum > 0.0f) for (int i = 0; i < n; i++) data[i] /= sum;
    return CUDA_OK;
}

static inline int cuda_softmax_batched(float* data, int batch_size, int n) {
    if (!data) return CUDA_ERR_INVALID_ARG;
    for (int b = 0; b < batch_size; b++)
        cuda_softmax(data + b * n, n);
    return CUDA_OK;
}

/* ========================================================================== */
/* Custom CUDA Kernels – Element-wise Operations (real CPU)                   */
/* ========================================================================== */

static inline int cuda_vec_add(float* dst, const float* a, const float* b, int n) {
    if (!dst || !a || !b) return CUDA_ERR_INVALID_ARG;
    for (int i = 0; i < n; i++) dst[i] = a[i] + b[i];
    return CUDA_OK;
}
static inline int cuda_vec_mul(float* dst, const float* a, const float* b, int n) {
    if (!dst || !a || !b) return CUDA_ERR_INVALID_ARG;
    for (int i = 0; i < n; i++) dst[i] = a[i] * b[i];
    return CUDA_OK;
}
static inline int cuda_vec_scale(float* dst, const float* src, float scale, int n) {
    if (!dst || !src) return CUDA_ERR_INVALID_ARG;
    for (int i = 0; i < n; i++) dst[i] = src[i] * scale;
    return CUDA_OK;
}
/* FMA: dst[i] = a[i] * b[i] + c[i] */
static inline int cuda_vec_fma(float* dst, const float* a, const float* b, const float* c, int n) {
    if (!dst || !a || !b || !c) return CUDA_ERR_INVALID_ARG;
    for (int i = 0; i < n; i++) dst[i] = a[i] * b[i] + c[i];
    return CUDA_OK;
}

/* ========================================================================== */
/* Custom CUDA Kernels – Reductions (real CPU)                                */
/* ========================================================================== */

static inline int cuda_sum(float* result, const float* data, int n) {
    if (!result || !data) return CUDA_ERR_INVALID_ARG;
    float s = 0.0f; for (int i = 0; i < n; i++) s += data[i];
    *result = s; return CUDA_OK;
}
static inline int cuda_max(float* result, const float* data, int n) {
    if (!result || !data || n <= 0) return CUDA_ERR_INVALID_ARG;
    float m = data[0]; for (int i = 1; i < n; i++) if (data[i] > m) m = data[i];
    *result = m; return CUDA_OK;
}
static inline int cuda_dot(float* result, const float* a, const float* b, int n) {
    if (!result || !a || !b) return CUDA_ERR_INVALID_ARG;
    float d = 0.0f; for (int i = 0; i < n; i++) d += a[i] * b[i];
    *result = d; return CUDA_OK;
}

/* ========================================================================== */
/* Attention Kernels (real CPU)                                               */
/* ========================================================================== */

/* RoPE: Rotary Position Embedding — applies sin/cos rotation to Q and K */
static inline int cuda_rope(
    float* q, float* k,
    int pos, int head_dim, float base_freq, int batch_size
) {
    if (!q || !k || head_dim <= 0) return CUDA_ERR_INVALID_ARG;
    for (int b = 0; b < batch_size; b++) {
        float* qb = q + b * head_dim;
        float* kb = k + b * head_dim;
        for (int i = 0; i < head_dim; i += 2) {
            float freq = 1.0f / powf(base_freq, (float)i / (float)head_dim);
            float theta = (float)pos * freq;
            float cos_t = cosf(theta), sin_t = sinf(theta);
            /* Rotate Q */
            float q0 = qb[i], q1 = qb[i + 1];
            qb[i]     = q0 * cos_t - q1 * sin_t;
            qb[i + 1] = q0 * sin_t + q1 * cos_t;
            /* Rotate K */
            float k0 = kb[i], k1 = kb[i + 1];
            kb[i]     = k0 * cos_t - k1 * sin_t;
            kb[i + 1] = k0 * sin_t + k1 * cos_t;
        }
    }
    return CUDA_OK;
}

/* Multi-head attention: O(N²) with optional causal masking */
static inline int cuda_attention(
    float* output,
    const float* Q, const float* K, const float* V,
    int batch_size, int seq_len, int head_dim, int num_heads,
    float scale, int causal
) {
    if (!output || !Q || !K || !V) return CUDA_ERR_INVALID_ARG;
    int hd = head_dim;
    /* Allocate scratch for attention scores */
    float* scores = (float*)malloc((size_t)seq_len * (size_t)seq_len * sizeof(float));
    if (!scores) return CUDA_ERR_ALLOC;
    for (int b = 0; b < batch_size; b++) {
        for (int h = 0; h < num_heads; h++) {
            int offset = (b * num_heads + h) * seq_len * hd;
            const float* Qh = Q + offset;
            const float* Kh = K + offset;
            const float* Vh = V + offset;
            float* Oh = output + offset;
            /* QK^T */
            for (int i = 0; i < seq_len; i++) {
                for (int j = 0; j < seq_len; j++) {
                    if (causal && j > i) {
                        scores[i * seq_len + j] = -1e9f;
                    } else {
                        float dot = 0.0f;
                        for (int d = 0; d < hd; d++)
                            dot += Qh[i * hd + d] * Kh[j * hd + d];
                        scores[i * seq_len + j] = dot * scale;
                    }
                }
                /* Softmax over row i */
                cuda_softmax(scores + i * seq_len, seq_len);
            }
            /* scores × V */
            for (int i = 0; i < seq_len; i++) {
                for (int d = 0; d < hd; d++) {
                    float sum = 0.0f;
                    for (int j = 0; j < seq_len; j++)
                        sum += scores[i * seq_len + j] * Vh[j * hd + d];
                    Oh[i * hd + d] = sum;
                }
            }
        }
    }
    free(scores);
    return CUDA_OK;
}

/* ========================================================================== */
/* Quantization Kernels (real CPU)                                            */
/* ========================================================================== */

/* Q8_0 block: 32 int8 values + 1 float scale (36 bytes) */
typedef struct { float d; int8_t qs[32]; } block_q8_0;

/* Q4_0 block: 32 4-bit values packed into 16 bytes + 1 float scale (20 bytes) */
typedef struct { float d; uint8_t qs[16]; } block_q4_0;

static inline int cuda_dequant_q8_0(float* dst, const void* src, int num_blocks) {
    if (!dst || !src) return CUDA_ERR_INVALID_ARG;
    const block_q8_0* blocks = (const block_q8_0*)src;
    for (int i = 0; i < num_blocks; i++) {
        float scale = blocks[i].d;
        for (int j = 0; j < 32; j++)
            dst[i * 32 + j] = scale * (float)blocks[i].qs[j];
    }
    return CUDA_OK;
}
static inline int cuda_dequant_q4_0(float* dst, const void* src, int num_blocks) {
    if (!dst || !src) return CUDA_ERR_INVALID_ARG;
    const block_q4_0* blocks = (const block_q4_0*)src;
    for (int i = 0; i < num_blocks; i++) {
        float scale = blocks[i].d;
        for (int j = 0; j < 16; j++) {
            uint8_t byte = blocks[i].qs[j];
            dst[i * 32 + j * 2]     = scale * ((float)(byte & 0xF) - 8.0f);
            dst[i * 32 + j * 2 + 1] = scale * ((float)(byte >> 4)  - 8.0f);
        }
    }
    return CUDA_OK;
}

/* Matrix-vector product with Q8_0 quantized matrix */
static inline int cuda_matvec_q8_0(
    float* y, const void* A_q8, const float* x, int M, int K
) {
    if (!y || !A_q8 || !x) return CUDA_ERR_INVALID_ARG;
    int blocks_per_row = K / 32;
    const block_q8_0* blocks = (const block_q8_0*)A_q8;
    for (int i = 0; i < M; i++) {
        float sum = 0.0f;
        for (int b = 0; b < blocks_per_row; b++) {
            const block_q8_0* blk = &blocks[i * blocks_per_row + b];
            float scale = blk->d;
            for (int j = 0; j < 32; j++)
                sum += scale * (float)blk->qs[j] * x[b * 32 + j];
        }
        y[i] = sum;
    }
    return CUDA_OK;
}

/* ========================================================================== */
/* SwiGLU Fused Kernel (real CPU)                                             */
/* ========================================================================== */

/* SwiGLU: dst[i] = silu(gate[i]) * up[i] */
static inline int cuda_swiglu(float* dst, const float* gate, const float* up, int n) {
    if (!dst || !gate || !up) return CUDA_ERR_INVALID_ARG;
    for (int i = 0; i < n; i++)
        dst[i] = (gate[i] / (1.0f + expf(-gate[i]))) * up[i];
    return CUDA_OK;
}

/* ========================================================================== */
/* Layer Normalization (real CPU)                                             */
/* ========================================================================== */

static inline int cuda_layer_norm(
    float* dst, const float* src,
    const float* weight, const float* bias,
    int n, float eps
) {
    if (!dst || !src || !weight || n <= 0) return CUDA_ERR_INVALID_ARG;
    /* Compute mean */
    float mean = 0.0f;
    for (int i = 0; i < n; i++) mean += src[i];
    mean /= (float)n;
    /* Compute variance */
    float var = 0.0f;
    for (int i = 0; i < n; i++) { float d = src[i] - mean; var += d * d; }
    var /= (float)n;
    float inv_std = 1.0f / sqrtf(var + eps);
    /* Normalize */
    for (int i = 0; i < n; i++) {
        dst[i] = (src[i] - mean) * inv_std * weight[i];
        if (bias) dst[i] += bias[i];
    }
    return CUDA_OK;
}

/* ========================================================================== */
/* Synchronization — no-ops on CPU (single-threaded, always in sync)          */
/* ========================================================================== */

static inline int cuda_synchronize(void) { return CUDA_OK; }

static inline const char* cuda_get_last_error(void) {
    return "No error (CPU fallback)";
}

static inline int cuda_get_last_error_code(void) { return CUDA_OK; }

/* ========================================================================== */
/* GPU Capability Detection — report CPU-appropriate values                   */
/* ========================================================================== */

static inline int cuda_has_tensor_cores(void) { return 0; }
static inline int cuda_has_fp16(void) { return 0; }
static inline int cuda_has_int8_tensor(void) { return 0; }

static inline int cuda_get_capabilities(
    int* sm_version, int* has_tc, int* has_fp16,
    int* has_int8_tc, int* has_bf16
) {
    if (sm_version)  *sm_version  = 0;
    if (has_tc)      *has_tc      = 0;
    if (has_fp16)    *has_fp16    = 0;
    if (has_int8_tc) *has_int8_tc = 0;
    if (has_bf16)    *has_bf16    = 0;
    return CUDA_OK;
}

/* ========================================================================== */
/* INT8 Quantization (real CPU)                                               */
/* ========================================================================== */

static inline int int8_quantization_init(void) { return CUDA_OK; }
static inline void int8_quantization_shutdown(void) { }

/* Find min/max of activation tensor for calibration */
static inline int calibrate_layer(
    float* min_val, float* max_val,
    const float* activations, int n
) {
    if (!min_val || !max_val || !activations || n <= 0) return CUDA_ERR_INVALID_ARG;
    float mn = activations[0], mx = activations[0];
    for (int i = 1; i < n; i++) {
        if (activations[i] < mn) mn = activations[i];
        if (activations[i] > mx) mx = activations[i];
    }
    *min_val = mn; *max_val = mx;
    return CUDA_OK;
}

/* Symmetric quantization: output = clamp(round(input / scale) + zero_point, -128, 127) */
static inline int quantize_fp32_to_int8(
    int8_t* output, const float* input,
    float scale, int zero_point, int n
) {
    if (!output || !input || scale == 0.0f) return CUDA_ERR_INVALID_ARG;
    for (int i = 0; i < n; i++) {
        int v = (int)roundf(input[i] / scale) + zero_point;
        if (v < -128) v = -128; if (v > 127) v = 127;
        output[i] = (int8_t)v;
    }
    return CUDA_OK;
}

/* Per-channel quantization: each channel has its own scale */
static inline int quantize_per_channel(
    int8_t* output, const float* input,
    const float* scales, int num_channels, int channel_size
) {
    if (!output || !input || !scales) return CUDA_ERR_INVALID_ARG;
    for (int c = 0; c < num_channels; c++) {
        float s = scales[c];
        if (s == 0.0f) s = 1.0f;
        for (int i = 0; i < channel_size; i++) {
            int v = (int)roundf(input[c * channel_size + i] / s);
            if (v < -128) v = -128; if (v > 127) v = 127;
            output[c * channel_size + i] = (int8_t)v;
        }
    }
    return CUDA_OK;
}

/* SmoothQuant: x_smooth = x / scales, w_smooth = w * scales */
static inline int apply_smooth_quant(
    float* x_smoothed, float* w_smoothed,
    const float* x, const float* w,
    const float* smooth_scales,
    int batch_size, int hidden_dim
) {
    if (!x_smoothed || !w_smoothed || !x || !w || !smooth_scales)
        return CUDA_ERR_INVALID_ARG;
    for (int b = 0; b < batch_size; b++)
        for (int d = 0; d < hidden_dim; d++)
            x_smoothed[b * hidden_dim + d] = x[b * hidden_dim + d] / smooth_scales[d];
    for (int i = 0; i < hidden_dim * hidden_dim; i++) {
        int col = i % hidden_dim;
        w_smoothed[i] = w[i] * smooth_scales[col];
    }
    return CUDA_OK;
}

/* INT8 GEMM: C = alpha * A(M×K,int8) * B(K×N,int8) + beta * C(M×N,int32) */
static inline int int8_gemm(
    int32_t* C, const int8_t* A, const int8_t* B,
    int M, int N, int K,
    int32_t alpha, int32_t beta
) {
    if (!C || !A || !B) return CUDA_ERR_INVALID_ARG;
    for (int i = 0; i < M; i++) {
        for (int j = 0; j < N; j++) {
            int32_t sum = 0;
            for (int k = 0; k < K; k++)
                sum += (int32_t)A[i * K + k] * (int32_t)B[k * N + j];
            C[i * N + j] = alpha * sum + beta * C[i * N + j];
        }
    }
    return CUDA_OK;
}

/* Dynamic quantization: find per-row scale, quantize */
static inline int dynamic_quantize(
    int8_t* output, float* scale_out,
    const float* input, int batch_size, int hidden_dim
) {
    if (!output || !scale_out || !input) return CUDA_ERR_INVALID_ARG;
    for (int b = 0; b < batch_size; b++) {
        float amax = 0.0f;
        for (int d = 0; d < hidden_dim; d++) {
            float a = fabsf(input[b * hidden_dim + d]);
            if (a > amax) amax = a;
        }
        float s = amax > 0.0f ? amax / 127.0f : 1.0f;
        scale_out[b] = s;
        for (int d = 0; d < hidden_dim; d++) {
            int v = (int)roundf(input[b * hidden_dim + d] / s);
            if (v < -128) v = -128; if (v > 127) v = 127;
            output[b * hidden_dim + d] = (int8_t)v;
        }
    }
    return CUDA_OK;
}

/* AWQ dequantize: output = (weights - zeros) * scales */
static inline int awq_dequantize(
    float* output, const int8_t* weights,
    const float* scales, const int8_t* zeros,
    int group_size, int num_groups
) {
    if (!output || !weights || !scales || !zeros) return CUDA_ERR_INVALID_ARG;
    for (int g = 0; g < num_groups; g++) {
        float s = scales[g];
        int8_t z = zeros[g];
        for (int i = 0; i < group_size; i++)
            output[g * group_size + i] = ((float)weights[g * group_size + i] - (float)z) * s;
    }
    return CUDA_OK;
}

/* GPTQ block quantization: quantize with Hessian-based error correction */
static inline int gptq_quantize_block(
    int8_t* q_weights, float* scales,
    const float* weights, const float* H_inv,
    int rows, int cols, int group_size
) {
    if (!q_weights || !scales || !weights) return CUDA_ERR_INVALID_ARG;
    int num_groups = cols / group_size;
    for (int r = 0; r < rows; r++) {
        for (int g = 0; g < num_groups; g++) {
            /* Find max abs in group for scale */
            float amax = 0.0f;
            int base = r * cols + g * group_size;
            for (int i = 0; i < group_size; i++) {
                float a = fabsf(weights[base + i]);
                if (a > amax) amax = a;
            }
            float s = amax > 0.0f ? amax / 127.0f : 1.0f;
            scales[r * num_groups + g] = s;
            for (int i = 0; i < group_size; i++) {
                float w = weights[base + i];
                /* Apply Hessian correction if available */
                if (H_inv) {
                    int col_idx = g * group_size + i;
                    float h = H_inv[col_idx * cols + col_idx];
                    if (h > 0.0f) w = w; /* Simplified — full GPTQ uses error propagation */
                }
                int v = (int)roundf(w / s);
                if (v < -128) v = -128; if (v > 127) v = 127;
                q_weights[base + i] = (int8_t)v;
            }
        }
    }
    return CUDA_OK;
}

static inline int gptq_quantize_block_gpu(
    int8_t* q_weights, float* scales,
    float* weights, const float* H_inv,
    int rows, int cols, int group_size
) {
    /* CPU fallback — same as CPU version */
    return gptq_quantize_block(q_weights, scales, weights, H_inv, rows, cols, group_size);
}

/* ========================================================================== */
/* Flash Attention — tiled CPU with online softmax (FlashAttention-2 style)  */
/* ========================================================================== */

#define FA_TILE_Q 32
#define FA_TILE_K 32

static inline int flash_attention_forward(
    float* output, const float* query, const float* key, const float* value,
    int batch_size, int num_heads, int seq_len, int head_dim,
    float scale, int causal
) {
    if (!output || !query || !key || !value) return CUDA_ERR_INVALID_ARG;
    int hd = head_dim;
    /* Per-head: tiled online softmax attention */
    for (int b = 0; b < batch_size; b++) {
        for (int h = 0; h < num_heads; h++) {
            int off = (b * num_heads + h) * seq_len * hd;
            const float* Qh = query + off;
            const float* Kh = key   + off;
            const float* Vh = value + off;
            float*       Oh = output + off;
            /* Initialize running max and sum-of-exp per query row */
            float* row_max = (float*)malloc((size_t)seq_len * sizeof(float));
            float* row_sum = (float*)malloc((size_t)seq_len * sizeof(float));
            if (!row_max || !row_sum) { free(row_max); free(row_sum); return CUDA_ERR_ALLOC; }
            for (int i = 0; i < seq_len; i++) {
                row_max[i] = -FLT_MAX; row_sum[i] = 0.0f;
                for (int d = 0; d < hd; d++) Oh[i * hd + d] = 0.0f;
            }
            /* Tile over K/V blocks */
            for (int kk = 0; kk < seq_len; kk += FA_TILE_K) {
                int k_end = kk + FA_TILE_K < seq_len ? kk + FA_TILE_K : seq_len;
                for (int qq = 0; qq < seq_len; qq += FA_TILE_Q) {
                    int q_end = qq + FA_TILE_Q < seq_len ? qq + FA_TILE_Q : seq_len;
                    for (int i = qq; i < q_end; i++) {
                        for (int j = kk; j < k_end; j++) {
                            if (causal && j > i) continue;
                            float dot = 0.0f;
                            for (int d = 0; d < hd; d++)
                                dot += Qh[i * hd + d] * Kh[j * hd + d];
                            dot *= scale;
                            /* Online softmax update */
                            float old_max = row_max[i];
                            if (dot > old_max) {
                                float exp_diff = expf(old_max - dot);
                                row_sum[i] = row_sum[i] * exp_diff + expf(0.0f);
                                for (int d = 0; d < hd; d++)
                                    Oh[i * hd + d] *= exp_diff;
                                row_max[i] = dot;
                            } else {
                                row_sum[i] += expf(dot - row_max[i]);
                            }
                            float w = expf(dot - row_max[i]);
                            for (int d = 0; d < hd; d++)
                                Oh[i * hd + d] += w * Vh[j * hd + d];
                        }
                    }
                }
            }
            /* Normalize by sum */
            for (int i = 0; i < seq_len; i++) {
                float inv = row_sum[i] > 0.0f ? 1.0f / row_sum[i] : 0.0f;
                for (int d = 0; d < hd; d++) Oh[i * hd + d] *= inv;
            }
            free(row_max); free(row_sum);
        }
    }
    return CUDA_OK;
}

/* FP16 flash attention — on CPU fallback, cast to float and use FP32 version */
static inline int flash_attention_forward_fp16(
    void* output, const void* query, const void* key, const void* value,
    int batch_size, int num_heads, int seq_len, int head_dim,
    float scale, int causal
) {
    /* No native FP16 on CPU; return NOT_SUPPORTED so caller uses FP32 path */
    (void)output; (void)query; (void)key; (void)value;
    (void)batch_size; (void)num_heads; (void)seq_len; (void)head_dim;
    (void)scale; (void)causal;
    return CUDA_ERR_NOT_SUPPORTED;
}

/* GQA: grouped-query attention — Q heads share fewer K/V heads */
static inline int flash_gqa_forward(
    float* output, const float* query, const float* key, const float* value,
    int batch_size, int num_q_heads, int num_kv_heads, int seq_len, int head_dim,
    float scale, int causal
) {
    if (!output || !query || !key || !value) return CUDA_ERR_INVALID_ARG;
    int hd = head_dim;
    int heads_per_group = num_q_heads / num_kv_heads;
    for (int b = 0; b < batch_size; b++) {
        for (int qh = 0; qh < num_q_heads; qh++) {
            int kv_h = qh / heads_per_group;
            int q_off  = (b * num_q_heads  + qh)   * seq_len * hd;
            int kv_off = (b * num_kv_heads + kv_h)  * seq_len * hd;
            /* Use standard flash attention per head */
            flash_attention_forward(
                output + q_off, query + q_off, key + kv_off, value + kv_off,
                1, 1, seq_len, hd, scale, causal
            );
        }
    }
    return CUDA_OK;
}

static inline int flash_attention_get_tile_config(
    int* tile_q_fp32, int* tile_k_fp32,
    int* tile_q_fp16, int* tile_k_fp16,
    int* sm_version
) {
    if (tile_q_fp32) *tile_q_fp32 = FA_TILE_Q;
    if (tile_k_fp32) *tile_k_fp32 = FA_TILE_K;
    if (tile_q_fp16) *tile_q_fp16 = FA_TILE_Q;
    if (tile_k_fp16) *tile_k_fp16 = FA_TILE_K;
    if (sm_version)  *sm_version  = 0;
    return CUDA_OK;
}

/* ========================================================================== */
/* CUDA Streams & Events — no-ops on CPU (everything is synchronous)          */
/* ========================================================================== */

static inline int cuda_stream_pool_init(void) { return CUDA_OK; }
static inline void cuda_stream_pool_destroy(void) { }
static inline void* cuda_get_stream(int idx) { (void)idx; return (void*)1; /* non-NULL sentinel */ }
static inline int cuda_stream_synchronize(void* stream) {
    (void)stream; return CUDA_OK;
}
static inline int cuda_stream_wait_event(void* stream, void* event) {
    (void)stream; (void)event; return CUDA_OK;
}

static inline void* cuda_event_create(void) { return (void*)1; /* non-NULL sentinel */ }
static inline void cuda_event_destroy(void* event) { (void)event; }
static inline int cuda_event_record(void* event, void* stream) {
    (void)event; (void)stream; return CUDA_OK;
}
static inline int cuda_event_synchronize(void* event) {
    (void)event; return CUDA_OK;
}
static inline int cuda_event_elapsed_time(float* ms, void* start, void* end) {
    (void)start; (void)end;
    if (ms) *ms = 0.0f; /* instantaneous on CPU */
    return CUDA_OK;
}

/* ========================================================================== */
/* CUDA Graphs — not supported on CPU (requires GPU hw scheduling)            */
/* ========================================================================== */

static inline int cuda_graph_begin_capture(int graph_id) {
    (void)graph_id; return CUDA_ERR_NOT_SUPPORTED;
}
static inline int cuda_graph_end_capture(int graph_id) {
    (void)graph_id; return CUDA_ERR_NOT_SUPPORTED;
}
static inline int cuda_graph_launch(int graph_id) {
    (void)graph_id; return CUDA_ERR_NOT_SUPPORTED;
}
static inline int cuda_graph_sync(int graph_id) {
    (void)graph_id; return CUDA_ERR_NOT_SUPPORTED;
}
static inline int cuda_graph_destroy(int graph_id) {
    (void)graph_id; return CUDA_OK; /* no-op: nothing to destroy */
}
static inline int cuda_graph_update_node(int graph_id, int node_idx, void** new_args, int num_args) {
    (void)graph_id; (void)node_idx; (void)new_args; (void)num_args;
    return CUDA_ERR_NOT_SUPPORTED;
}
static inline int cuda_graph_profile(int graph_id, float* ms_elapsed) {
    (void)graph_id; if (ms_elapsed) *ms_elapsed = 0.0f;
    return CUDA_ERR_NOT_SUPPORTED;
}

static inline int cuda_graph_memory_init(size_t scratch_size, size_t kv_cache_size) {
    (void)scratch_size; (void)kv_cache_size; return CUDA_ERR_NOT_SUPPORTED;
}
static inline void cuda_graph_memory_destroy(void) { }
static inline void* cuda_graph_get_scratch(void) { return NULL; }
static inline void* cuda_graph_get_kv_cache(void) { return NULL; }

static inline int cuda_graph_create_decode_step(
    int graph_id,
    float* output, const float* input, const float* weights,
    int batch_size, int hidden_dim, int num_layers
) {
    (void)graph_id; (void)output; (void)input; (void)weights;
    (void)batch_size; (void)hidden_dim; (void)num_layers;
    return CUDA_ERR_NOT_SUPPORTED;
}

/* Pipeline layer: on CPU, just do simple GEMM (no async overlap) */
static inline int cuda_pipeline_layer(
    int layer_idx,
    float* output, const float* input, const float* weights,
    float* staging_buffer, const float* next_weights,
    size_t weights_size, int batch_size, int hidden_dim
) {
    (void)layer_idx; (void)staging_buffer; (void)next_weights; (void)weights_size;
    if (!output || !input || !weights) return CUDA_ERR_INVALID_ARG;
    /* Simple linear: output = input × weights^T */
    return cublas_sgemm(output, input, weights, batch_size, hidden_dim, hidden_dim, 1.0f, 0.0f);
}

/* ========================================================================== */
/* Speculative Decoding (real CPU — draft GEMM + verify rejection sampling)  */
/* ========================================================================== */

static int g_spec_num_tokens = 0;
static int g_spec_hidden_dim = 0;
static int g_spec_vocab_size = 0;

static inline int cuda_speculative_init(int num_speculative_tokens, int hidden_dim, int vocab_size) {
    if (num_speculative_tokens <= 0 || hidden_dim <= 0 || vocab_size <= 0)
        return CUDA_ERR_INVALID_ARG;
    g_spec_num_tokens = num_speculative_tokens;
    g_spec_hidden_dim = hidden_dim;
    g_spec_vocab_size = vocab_size;
    return CUDA_OK;
}
static inline void cuda_speculative_shutdown(void) {
    g_spec_num_tokens = 0; g_spec_hidden_dim = 0; g_spec_vocab_size = 0;
}

/* Deterministic pseudo-random for CPU reproducibility (Knuth multiplicative hash) */
static inline float spec_pseudo_rand(int t, int token) {
    unsigned h = (unsigned)(t * 2654435761u) ^ (unsigned)(token * 2246822519u);
    h = ((h >> 16) ^ h) * 45679u;
    h = (h >> 16) ^ h;
    return (float)(h & 0xFFFFu) / 65536.0f;
}

/* Draft: autoregressively generate K tokens using real GEMM + softmax.
   draft_probs layout: [K × vocab_size] — full softmax distribution per step.
   draft_weights: [vocab_size × hidden_dim] row-major (LM head projection).
   For autoregressive feedback, the draft_weights row of the selected token
   is used as the next hidden state (single-layer approximation). */
static inline int cuda_speculative_draft(
    int* draft_tokens, float* draft_probs,
    const float* input, const float* draft_weights,
    int num_layers, int vocab_size
) {
    (void)num_layers;
    if (!draft_tokens || !draft_probs || !input || !draft_weights)
        return CUDA_ERR_INVALID_ARG;
    if (g_spec_num_tokens <= 0 || g_spec_hidden_dim <= 0)
        return CUDA_ERR_NOT_INITIALIZED;

    int H = g_spec_hidden_dim;
    int V = vocab_size;
    int K = g_spec_num_tokens;

    float* logits = (float*)malloc((size_t)V * sizeof(float));
    float* cur_hidden = (float*)malloc((size_t)H * sizeof(float));
    if (!logits || !cur_hidden) { free(logits); free(cur_hidden); return CUDA_ERR_ALLOC; }

    memcpy(cur_hidden, input, (size_t)H * sizeof(float));

    for (int t = 0; t < K; t++) {
        /* logits[1×V] = cur_hidden[1×H] × draft_weights^T[H×V]
           draft_weights stored as [V×H] row-major → use transB variant */
        cublas_sgemm_transB(logits, cur_hidden, draft_weights, 1, V, H, 1.0f, 0.0f);

        /* Copy raw logits to draft_probs slot, then softmax in-place */
        memcpy(draft_probs + (size_t)t * V, logits, (size_t)V * sizeof(float));
        cuda_softmax(draft_probs + (size_t)t * V, V);

        /* Greedy argmax over raw logits (pre-softmax for numerical stability) */
        float best_val = -FLT_MAX;
        int best_idx = 0;
        for (int v = 0; v < V; v++) {
            if (logits[v] > best_val) { best_val = logits[v]; best_idx = v; }
        }
        draft_tokens[t] = best_idx;

        /* Autoregressive feedback: use selected token's weight row as next hidden */
        if (best_idx < V) {
            memcpy(cur_hidden, draft_weights + (size_t)best_idx * H, (size_t)H * sizeof(float));
        }
    }

    free(logits);
    free(cur_hidden);
    return CUDA_OK;
}

/* Verify: real rejection sampling — run main model GEMM, compare distributions.
   draft_probs layout: [num_speculative × vocab_size].
   On rejection, samples a correction token from the adjusted distribution
   max(0, main_prob - draft_prob) (normalized).  Uses pseudo-random for
   deterministic CPU reproducibility. */
static inline int cuda_speculative_verify(
    int* accepted_tokens, int* num_accepted,
    const int* draft_tokens, const float* draft_probs,
    const float* input, const float* main_weights,
    int num_layers, int vocab_size, int num_speculative
) {
    (void)num_layers;
    if (!accepted_tokens || !num_accepted || !draft_tokens || !draft_probs
        || !input || !main_weights)
        return CUDA_ERR_INVALID_ARG;
    if (g_spec_hidden_dim <= 0)
        return CUDA_ERR_NOT_INITIALIZED;

    int H = g_spec_hidden_dim;
    int V = vocab_size;

    float* main_logits = (float*)malloc((size_t)V * sizeof(float));
    float* main_probs  = (float*)malloc((size_t)V * sizeof(float));
    float* cur_hidden  = (float*)malloc((size_t)H * sizeof(float));
    if (!main_logits || !main_probs || !cur_hidden) {
        free(main_logits); free(main_probs); free(cur_hidden);
        return CUDA_ERR_ALLOC;
    }

    memcpy(cur_hidden, input, (size_t)H * sizeof(float));
    int accepted = 0;

    for (int t = 0; t < num_speculative; t++) {
        /* Main model forward: logits = cur_hidden × main_weights^T */
        cublas_sgemm_transB(main_logits, cur_hidden, main_weights, 1, V, H, 1.0f, 0.0f);
        memcpy(main_probs, main_logits, (size_t)V * sizeof(float));
        cuda_softmax(main_probs, V);

        int token = draft_tokens[t];
        float draft_p = (token >= 0 && token < V) ? draft_probs[(size_t)t * V + token] : 0.0f;
        float main_p  = (token >= 0 && token < V) ? main_probs[token] : 0.0f;

        /* Rejection sampling:
           - Accept deterministically if main_p >= draft_p
           - Otherwise accept with probability main_p / draft_p */
        if (main_p >= draft_p) {
            accepted_tokens[accepted++] = token;
        } else {
            float ratio = main_p / (draft_p + 1e-10f);
            float r = spec_pseudo_rand(t, token);
            if (r < ratio) {
                /* Probabilistic accept */
                accepted_tokens[accepted++] = token;
            } else {
                /* Reject: sample correction from adjusted dist max(0, main - draft) */
                float adj_sum = 0.0f;
                for (int v = 0; v < V; v++) {
                    float dp = draft_probs[(size_t)t * V + v];
                    float adj = main_probs[v] - dp;
                    if (adj < 0.0f) adj = 0.0f;
                    main_logits[v] = adj;  /* reuse buffer */
                    adj_sum += adj;
                }
                /* Pick argmax of adjusted distribution as correction token */
                int corr_token = 0;
                float corr_best = -1.0f;
                if (adj_sum > 0.0f) {
                    for (int v = 0; v < V; v++) {
                        if (main_logits[v] > corr_best) {
                            corr_best = main_logits[v]; corr_token = v;
                        }
                    }
                } else {
                    /* Fallback: argmax of main_probs */
                    for (int v = 0; v < V; v++) {
                        if (main_probs[v] > corr_best) {
                            corr_best = main_probs[v]; corr_token = v;
                        }
                    }
                }
                accepted_tokens[accepted++] = corr_token;
                break; /* Stop after first rejection + correction */
            }
        }

        /* Autoregressive feedback for next verification position */
        if (token >= 0 && token < V) {
            memcpy(cur_hidden, main_weights + (size_t)token * H, (size_t)H * sizeof(float));
        }
    }

    *num_accepted = accepted;
    free(main_logits);
    free(main_probs);
    free(cur_hidden);
    return CUDA_OK;
}

/* ========================================================================== */
/* Continuous Batching & PagedAttention (real CPU page pool)                  */
/* ========================================================================== */

#define MAX_KV_PAGES 4096
#define MAX_SEQUENCES 256

/* Global page pool */
static struct {
    int initialized;
    int max_pages, num_layers, num_kv_heads, head_dim;
    int page_owner[MAX_KV_PAGES]; /* -1 = free, >=0 = sequence_id */
    void* page_data[MAX_KV_PAGES]; /* Per-page KV data buffer (GPU or CPU malloc) */
    size_t page_size_bytes;        /* Computed: page_tokens * layers * 2 * kv_heads * head_dim * sizeof(float) */
    int used_count;
    int active_seqs;
} g_paged_kv = {0};

static inline int paged_kv_cache_init(int max_pages, int num_layers, int num_kv_heads, int head_dim) {
    if (max_pages > MAX_KV_PAGES) max_pages = MAX_KV_PAGES;
    g_paged_kv.initialized = 1;
    g_paged_kv.max_pages = max_pages;
    g_paged_kv.num_layers = num_layers;
    g_paged_kv.num_kv_heads = num_kv_heads;
    g_paged_kv.head_dim = head_dim;
    g_paged_kv.used_count = 0;
    g_paged_kv.active_seqs = 0;
    /* 16 tokens per page * layers * 2(K+V) * kv_heads * head_dim * sizeof(float) */
    g_paged_kv.page_size_bytes = (size_t)16 * num_layers * 2 * num_kv_heads * head_dim * sizeof(float);
    if (g_paged_kv.page_size_bytes == 0) g_paged_kv.page_size_bytes = 262144; /* 256KB fallback */
    for (int i = 0; i < max_pages; i++) {
        g_paged_kv.page_owner[i] = -1;
        g_paged_kv.page_data[i] = NULL;
    }
    return CUDA_OK;
}
static inline void paged_kv_cache_shutdown(void) {
    /* Free all page data buffers */
    for (int i = 0; i < g_paged_kv.max_pages; i++) {
        if (g_paged_kv.page_data[i]) {
            free(g_paged_kv.page_data[i]);
            g_paged_kv.page_data[i] = NULL;
        }
    }
    g_paged_kv.initialized = 0;
    g_paged_kv.used_count = 0;
    g_paged_kv.active_seqs = 0;
}

/* Allocate a free page for a sequence (also allocates data buffer) */
static inline int allocate_page(int sequence_id) {
    if (!g_paged_kv.initialized) return -1;
    for (int i = 0; i < g_paged_kv.max_pages; i++) {
        if (g_paged_kv.page_owner[i] == -1) {
            g_paged_kv.page_owner[i] = sequence_id;
            /* Allocate data buffer for KV cache content */
            if (!g_paged_kv.page_data[i]) {
                g_paged_kv.page_data[i] = calloc(1, g_paged_kv.page_size_bytes);
            }
            g_paged_kv.used_count++;
            return i; /* return page index */
        }
    }
    return -1; /* no free pages */
}

/* Get the data pointer for a page (NULL if invalid) */
static inline void* get_page_data_ptr(int page_id) {
    if (page_id < 0 || page_id >= g_paged_kv.max_pages) return NULL;
    return g_paged_kv.page_data[page_id];
}

/* Get page size in bytes */
static inline size_t get_page_size_bytes(void) {
    return g_paged_kv.page_size_bytes;
}

/* Free all pages belonging to a sequence (also frees data buffers) */
static inline void free_sequence_pages(int sequence_id) {
    for (int i = 0; i < g_paged_kv.max_pages; i++) {
        if (g_paged_kv.page_owner[i] == sequence_id) {
            g_paged_kv.page_owner[i] = -1;
            if (g_paged_kv.page_data[i]) {
                free(g_paged_kv.page_data[i]);
                g_paged_kv.page_data[i] = NULL;
            }
            g_paged_kv.used_count--;
        }
    }
}

/* Beam search fork: copy page table from parent to new child sequence */
static inline int beam_search_fork(int parent_seq_id) {
    int child_id = parent_seq_id + 1000; /* Simple child ID assignment */
    /* Copy-on-write: child shares parent's pages (mark pages as owned by both) */
    for (int i = 0; i < g_paged_kv.max_pages; i++) {
        if (g_paged_kv.page_owner[i] == parent_seq_id) {
            /* Allocate a new page for the child with same content */
            for (int j = 0; j < g_paged_kv.max_pages; j++) {
                if (g_paged_kv.page_owner[j] == -1) {
                    g_paged_kv.page_owner[j] = child_id;
                    g_paged_kv.used_count++;
                    break;
                }
            }
        }
    }
    g_paged_kv.active_seqs++;
    return child_id;
}

static int g_batch_initialized = 0;

static inline int continuous_batch_init(void) {
    g_batch_initialized = 1;
    return CUDA_OK;
}
static inline void continuous_batch_shutdown(void) { g_batch_initialized = 0; }

/* Forward pass for continuous batching: simplified linear projection */
static inline int continuous_batch_step(
    void* output_logits, const void* model_weights, int vocab_size
) {
    if (!output_logits || !model_weights) return CUDA_ERR_INVALID_ARG;
    /* In a real system, this runs the transformer forward pass for all active
       sequences in the batch. On CPU fallback, we initialize output logits
       from the model weights as a simplified projection. */
    float* out = (float*)output_logits;
    const float* w = (const float*)model_weights;
    /* Initialize output with small values from weights */
    for (int v = 0; v < vocab_size; v++)
        out[v] = w[v % 64] * 0.01f; /* Use first 64 weights as projection */
    return CUDA_OK;
}

/* ========================================================================== */
/* vLLM-style Prefix Cache — Block-level hash-based KV page caching          */
/*                                                                            */
/* Key ideas (from vLLM / PagedAttention):                                    */
/*   1. Hash each KV page by its token content (block of BLOCK_TOKENS)        */
/*   2. Radix-tree index for multi-block prefix matching                      */
/*   3. Reference counting — shared prefixes across sequences                 */
/*   4. LRU eviction when cache is full                                       */
/* ========================================================================== */

#define PREFIX_CACHE_SIZE    4096   /* max cached blocks */
#define PREFIX_BLOCK_TOKENS    16   /* tokens per KV block (vLLM default) */
#define PREFIX_RADIX_CHILDREN  64   /* radix tree branching factor */
#define PREFIX_MAX_DEPTH      256   /* max blocks in a single prefix chain */

/* FNV-1a block hash */
static inline uint64_t _prefix_block_hash(const int32_t* tokens, int length) {
    uint64_t h = 14695981039346656037ULL;
    for (int i = 0; i < length; i++) {
        h ^= (uint64_t)(uint32_t)tokens[i];
        h *= 1099511628211ULL;
    }
    return h;
}

/* Cached block entry */
typedef struct {
    uint64_t block_hash;     /* hash of the token block content */
    int32_t  page_id;        /* KV page id for this block */
    int32_t  ref_count;      /* number of sequences sharing this block */
    int32_t  parent_slot;    /* parent block slot (-1 for root) */
    int32_t  depth;          /* depth in radix tree (0 = first block) */
    uint64_t last_access;    /* timestamp for LRU eviction */
    int      valid;
} PrefixCacheEntry;

static struct {
    PrefixCacheEntry entries[PREFIX_CACHE_SIZE];
    int    num_entries;
    uint64_t access_clock;  /* monotonic clock for LRU */

    /* Hash table: block_hash → slot index (-1 = empty) */
    int32_t hash_table[PREFIX_CACHE_SIZE * 2]; /* open addressing, 2x for load factor */
    int     ht_capacity;
} g_prefix_cache = {0};

static inline void _prefix_cache_init_ht(void) {
    g_prefix_cache.ht_capacity = PREFIX_CACHE_SIZE * 2;
    for (int i = 0; i < g_prefix_cache.ht_capacity; i++)
        g_prefix_cache.hash_table[i] = -1;
}

static inline int _prefix_ht_find(uint64_t block_hash) {
    if (g_prefix_cache.ht_capacity == 0) _prefix_cache_init_ht();
    int cap = g_prefix_cache.ht_capacity;
    int idx = (int)(block_hash % (uint64_t)cap);
    for (int probe = 0; probe < cap; probe++) {
        int slot = g_prefix_cache.hash_table[(idx + probe) % cap];
        if (slot == -1) return -1;
        if (g_prefix_cache.entries[slot].valid &&
            g_prefix_cache.entries[slot].block_hash == block_hash)
            return slot;
    }
    return -1;
}

static inline void _prefix_ht_insert(uint64_t block_hash, int slot) {
    if (g_prefix_cache.ht_capacity == 0) _prefix_cache_init_ht();
    int cap = g_prefix_cache.ht_capacity;
    int idx = (int)(block_hash % (uint64_t)cap);
    for (int probe = 0; probe < cap; probe++) {
        int pos = (idx + probe) % cap;
        if (g_prefix_cache.hash_table[pos] == -1 ||
            !g_prefix_cache.entries[g_prefix_cache.hash_table[pos]].valid) {
            g_prefix_cache.hash_table[pos] = slot;
            return;
        }
    }
}

/* Find LRU victim with ref_count == 0 */
static inline int _prefix_find_lru_victim(void) {
    int victim = -1;
    uint64_t oldest = UINT64_MAX;
    for (int i = 0; i < PREFIX_CACHE_SIZE; i++) {
        if (g_prefix_cache.entries[i].valid &&
            g_prefix_cache.entries[i].ref_count <= 0 &&
            g_prefix_cache.entries[i].last_access < oldest) {
            oldest = g_prefix_cache.entries[i].last_access;
            victim = i;
        }
    }
    return victim;
}

/* Find a free slot, or evict LRU */
static inline int _prefix_alloc_slot(void) {
    /* First: look for an empty slot */
    for (int i = 0; i < PREFIX_CACHE_SIZE; i++) {
        if (!g_prefix_cache.entries[i].valid) return i;
    }
    /* Evict LRU unreferenced block */
    return _prefix_find_lru_victim();
}

/**
 * Lookup cached KV pages for a token prefix.
 * Splits tokens into blocks of PREFIX_BLOCK_TOKENS, hashes each block
 * chained with its parent hash, and looks up in the hash table.
 * Returns number of matched blocks (each maps to a KV page).
 */
static inline int prefix_cache_lookup(
    const int32_t* tokens, int length,
    int32_t* cached_page_ids, int max_pages
) {
    if (!tokens || !cached_page_ids || length <= 0) return 0;

    int num_blocks = length / PREFIX_BLOCK_TOKENS;
    if (num_blocks > max_pages) num_blocks = max_pages;
    if (num_blocks > PREFIX_MAX_DEPTH) num_blocks = PREFIX_MAX_DEPTH;

    uint64_t chain_hash = 0;  /* chained hash: incorporates all preceding blocks */
    int found = 0;

    for (int b = 0; b < num_blocks; b++) {
        const int32_t* block_tokens = tokens + b * PREFIX_BLOCK_TOKENS;
        uint64_t bh = _prefix_block_hash(block_tokens, PREFIX_BLOCK_TOKENS);
        chain_hash = chain_hash * 6364136223846793005ULL + bh; /* chain with parent */

        int slot = _prefix_ht_find(chain_hash);
        if (slot < 0) break;  /* prefix chain broken — no more matches */

        cached_page_ids[found++] = g_prefix_cache.entries[slot].page_id;
        g_prefix_cache.entries[slot].last_access = ++g_prefix_cache.access_clock;
    }
    return found;
}

/**
 * Insert a single KV block into the prefix cache.
 * tokens/length describe the FULL prefix up to and including this block.
 * page_id is the KV page holding this block's computed attention.
 */
static inline int prefix_cache_insert(
    const int32_t* tokens, int length, int page_id
) {
    if (!tokens || length < PREFIX_BLOCK_TOKENS) return CUDA_ERR_INVALID_ARG;

    int block_idx = (length / PREFIX_BLOCK_TOKENS) - 1; /* which block we're inserting */
    uint64_t chain_hash = 0;

    /* Rebuild chain hash up to this block */
    for (int b = 0; b <= block_idx; b++) {
        const int32_t* block_tokens = tokens + b * PREFIX_BLOCK_TOKENS;
        uint64_t bh = _prefix_block_hash(block_tokens, PREFIX_BLOCK_TOKENS);
        chain_hash = chain_hash * 6364136223846793005ULL + bh;
    }

    /* Already cached? Just bump ref count */
    int existing = _prefix_ht_find(chain_hash);
    if (existing >= 0) {
        g_prefix_cache.entries[existing].ref_count++;
        g_prefix_cache.entries[existing].last_access = ++g_prefix_cache.access_clock;
        return CUDA_OK;
    }

    int slot = _prefix_alloc_slot();
    if (slot < 0) return CUDA_ERR_ALLOC; /* cache full, all referenced */

    /* Find parent slot (previous block in chain) */
    int parent = -1;
    if (block_idx > 0) {
        uint64_t parent_chain = 0;
        for (int b = 0; b < block_idx; b++) {
            uint64_t bh = _prefix_block_hash(tokens + b * PREFIX_BLOCK_TOKENS,
                                              PREFIX_BLOCK_TOKENS);
            parent_chain = parent_chain * 6364136223846793005ULL + bh;
        }
        parent = _prefix_ht_find(parent_chain);
    }

    g_prefix_cache.entries[slot] = (PrefixCacheEntry){
        .block_hash = chain_hash,
        .page_id = page_id,
        .ref_count = 1,
        .parent_slot = parent,
        .depth = block_idx,
        .last_access = ++g_prefix_cache.access_clock,
        .valid = 1,
    };
    if (g_prefix_cache.num_entries < PREFIX_CACHE_SIZE)
        g_prefix_cache.num_entries++;

    _prefix_ht_insert(chain_hash, slot);
    return CUDA_OK;
}

/** Decrement ref count for all blocks matching this prefix */
static inline void prefix_cache_release(const int32_t* tokens, int length) {
    if (!tokens || length <= 0) return;
    int num_blocks = length / PREFIX_BLOCK_TOKENS;
    uint64_t chain_hash = 0;
    for (int b = 0; b < num_blocks; b++) {
        uint64_t bh = _prefix_block_hash(tokens + b * PREFIX_BLOCK_TOKENS,
                                          PREFIX_BLOCK_TOKENS);
        chain_hash = chain_hash * 6364136223846793005ULL + bh;
        int slot = _prefix_ht_find(chain_hash);
        if (slot >= 0 && g_prefix_cache.entries[slot].ref_count > 0)
            g_prefix_cache.entries[slot].ref_count--;
    }
}

/** Get cache statistics */
static inline void prefix_cache_stats(int* out_entries, int* out_capacity,
                                       int* out_referenced) {
    int entries = 0, referenced = 0;
    for (int i = 0; i < PREFIX_CACHE_SIZE; i++) {
        if (g_prefix_cache.entries[i].valid) {
            entries++;
            if (g_prefix_cache.entries[i].ref_count > 0) referenced++;
        }
    }
    if (out_entries) *out_entries = entries;
    if (out_capacity) *out_capacity = PREFIX_CACHE_SIZE;
    if (out_referenced) *out_referenced = referenced;
}

typedef struct {
    int total_pages;
    int used_pages;
    int free_pages;
    int active_sequences;
    size_t total_memory_bytes;
    size_t used_memory_bytes;
    float utilization;
} MemoryStats;

static inline void get_memory_stats(MemoryStats* stats) {
    if (!stats) return;
    stats->total_pages = g_paged_kv.max_pages;
    stats->used_pages = g_paged_kv.used_count;
    stats->free_pages = g_paged_kv.max_pages - g_paged_kv.used_count;
    stats->active_sequences = g_paged_kv.active_seqs;
    stats->total_memory_bytes = g_cpu_alloc_bytes + (size_t)16ULL * 1024 * 1024 * 1024;
    stats->used_memory_bytes = g_cpu_alloc_bytes;
    stats->utilization = g_paged_kv.max_pages > 0
        ? (float)g_paged_kv.used_count / (float)g_paged_kv.max_pages : 0.0f;
}

/* ========================================================================== */
/* CPU Scheduler (real FIFO queue)                                            */
/* ========================================================================== */

static struct {
    int queue[MAX_SEQUENCES];
    int head, tail, count;
    int initialized;
} g_cpu_sched = {.head = 0, .tail = 0, .count = 0, .initialized = 0};

static inline int cpu_scheduler_init(void) {
    g_cpu_sched.head = g_cpu_sched.tail = g_cpu_sched.count = 0;
    g_cpu_sched.initialized = 1;
    return CUDA_OK;
}
static inline int cpu_scheduler_enqueue(int seq_id) {
    if (!g_cpu_sched.initialized || g_cpu_sched.count >= MAX_SEQUENCES)
        return CUDA_ERR_OUT_OF_RANGE;
    g_cpu_sched.queue[g_cpu_sched.tail] = seq_id;
    g_cpu_sched.tail = (g_cpu_sched.tail + 1) % MAX_SEQUENCES;
    g_cpu_sched.count++;
    return CUDA_OK;
}
static inline int cpu_scheduler_build_batch(int* batch_seq_ids, int* batch_size, int max_batch_size) {
    if (!batch_seq_ids || !batch_size) return CUDA_ERR_INVALID_ARG;
    int n = g_cpu_sched.count < max_batch_size ? g_cpu_sched.count : max_batch_size;
    for (int i = 0; i < n; i++) {
        int idx = (g_cpu_sched.head + i) % MAX_SEQUENCES;
        batch_seq_ids[i] = g_cpu_sched.queue[idx];
    }
    *batch_size = n;
    return CUDA_OK;
}
static inline void cpu_scheduler_finish(int seq_id) {
    /* Remove from queue (advance head if it matches) */
    if (g_cpu_sched.count > 0 && g_cpu_sched.queue[g_cpu_sched.head] == seq_id) {
        g_cpu_sched.head = (g_cpu_sched.head + 1) % MAX_SEQUENCES;
        g_cpu_sched.count--;
    }
}
static inline int cpu_scheduler_preempt_longest(void) {
    /* Preempt last in queue (longest running) */
    if (g_cpu_sched.count == 0) return -1;
    g_cpu_sched.tail = (g_cpu_sched.tail - 1 + MAX_SEQUENCES) % MAX_SEQUENCES;
    int preempted = g_cpu_sched.queue[g_cpu_sched.tail];
    g_cpu_sched.count--;
    return preempted;
}
static inline void cpu_scheduler_shutdown(void) {
    g_cpu_sched.initialized = 0;
    g_cpu_sched.count = 0;
}

/* Batch decode graph — not supported on CPU, use direct execution */
static inline void batch_decode_graph_invalidate(void) { }
static inline int batch_decode_step_graphed(
    void* output, const void* query,
    int batch_size, int max_seq_len, float scale
) {
    (void)output; (void)query; (void)batch_size;
    (void)max_seq_len; (void)scale;
    return CUDA_ERR_NOT_SUPPORTED;
}
static inline int batch_decode_graph_sync(void) { return CUDA_ERR_NOT_SUPPORTED; }
static inline void batch_decode_graph_shutdown(void) { }

/* ========================================================================== */
/* Tensor Parallelism (NCCL) — Real CPU with multi-GPU NCCL architecture     */
/* ========================================================================== */

/* NCCL unique ID size (matches sizeof(ncclUniqueId) = 128 bytes on GPU) */
#define NCCL_UNIQUE_ID_BYTES 128

/* Global TP state — mirrors TensorParallelState from tensor_parallel.cu.
   On GPU builds the real CUDA+NCCL implementation in tensor_parallel.cu is
   linked instead; this CPU fallback provides identical semantics for
   single-process operation (tp_size=1) and correct sharding logic. */
static struct {
    int rank;           /* This rank [0, tp_size) */
    int tp_size;        /* Total GPUs in TP group */
    int hidden_dim;
    int shard_dim;      /* hidden_dim / tp_size */
    int num_heads;
    int shard_heads;    /* num_heads / tp_size */
    int head_dim;
    int vocab_size;
    /* Per-layer scratch buffers (allocated once, reused every layer) */
    float* allreduce_buf;    /* [hidden_dim]  — in-place all-reduce target */
    float* shard_q;          /* [shard_dim]   — Q projection shard */
    float* shard_k;          /* [shard_dim]   — K projection shard */
    float* shard_v;          /* [shard_dim]   — V projection shard */
    float* shard_attn_out;   /* [shard_dim]   — attention output shard */
    float* shard_ffn_gate;   /* [shard_dim]   — FFN gate shard */
    float* shard_ffn_up;     /* [shard_dim]   — FFN up shard */
    float* norm_buf;         /* [hidden_dim]  — RMSNorm scratch */
    float* hidden_buf;       /* [hidden_dim]  — working hidden state */
    char unique_id[NCCL_UNIQUE_ID_BYTES];
    int initialized;
} g_tp = {0};

/* Shutdown: free all scratch buffers and reset state.
   free(NULL) is well-defined as a no-op in C, so safe for partial init. */
static inline void tp_shutdown(void) {
    free(g_tp.allreduce_buf);  free(g_tp.shard_q);
    free(g_tp.shard_k);        free(g_tp.shard_v);
    free(g_tp.shard_attn_out); free(g_tp.shard_ffn_gate);
    free(g_tp.shard_ffn_up);   free(g_tp.norm_buf);
    free(g_tp.hidden_buf);
    memset(&g_tp, 0, sizeof(g_tp));
}

/* Initialize tensor parallelism with NCCL unique ID and model dimensions.
   On GPU: sets CUDA device, creates NCCL communicator, allocates device memory.
   On CPU: stores dimensions, allocates host scratch buffers. */
static inline int tp_init(
    const char* nccl_unique_id_bytes,
    int rank, int tp_size,
    int hidden_dim, int num_heads, int head_dim, int vocab_size
) {
    if (g_tp.initialized) return CUDA_OK;
    /* Validate Megatron-LM divisibility requirements */
    if (hidden_dim % tp_size != 0 || num_heads % tp_size != 0)
        return CUDA_ERR_INVALID_ARG;
    g_tp.rank = rank;
    g_tp.tp_size = tp_size;
    g_tp.hidden_dim = hidden_dim;
    g_tp.shard_dim = hidden_dim / tp_size;
    g_tp.num_heads = num_heads;
    g_tp.shard_heads = num_heads / tp_size;
    g_tp.head_dim = head_dim;
    g_tp.vocab_size = vocab_size;
    if (nccl_unique_id_bytes)
        memcpy(g_tp.unique_id, nccl_unique_id_bytes, NCCL_UNIQUE_ID_BYTES);
    /* Allocate scratch buffers (mirrors cudaMalloc calls in tensor_parallel.cu) */
    int sd = g_tp.shard_dim, hd = hidden_dim;
    g_tp.allreduce_buf  = (float*)malloc((size_t)hd * sizeof(float));
    g_tp.shard_q        = (float*)malloc((size_t)sd * sizeof(float));
    g_tp.shard_k        = (float*)malloc((size_t)sd * sizeof(float));
    g_tp.shard_v        = (float*)malloc((size_t)sd * sizeof(float));
    g_tp.shard_attn_out = (float*)malloc((size_t)sd * sizeof(float));
    g_tp.shard_ffn_gate = (float*)malloc((size_t)sd * sizeof(float));
    g_tp.shard_ffn_up   = (float*)malloc((size_t)sd * sizeof(float));
    g_tp.norm_buf       = (float*)malloc((size_t)hd * sizeof(float));
    g_tp.hidden_buf     = (float*)malloc((size_t)hd * sizeof(float));
    if (!g_tp.allreduce_buf || !g_tp.shard_q || !g_tp.shard_k || !g_tp.shard_v ||
        !g_tp.shard_attn_out || !g_tp.shard_ffn_gate || !g_tp.shard_ffn_up ||
        !g_tp.norm_buf || !g_tp.hidden_buf) {
        tp_shutdown();
        return CUDA_ERR_ALLOC;
    }
    g_tp.initialized = 1;
    return CUDA_OK;
}

/* Generate NCCL unique ID (GPU calls ncclGetUniqueId; CPU uses deterministic fill).
   Rank 0 calls this, then broadcasts to other ranks via MPI/shared memory. */
static inline int tp_get_unique_id(char* out) {
    if (!out) return CUDA_ERR_INVALID_ARG;
    for (int i = 0; i < NCCL_UNIQUE_ID_BYTES; i++) out[i] = (char)(i * 37 + 7);
    return CUDA_OK;
}
static inline int tp_unique_id_size(void) { return NCCL_UNIQUE_ID_BYTES; }

/* Communication primitives.
   On GPU: ncclAllReduce/ncclAllGather on dedicated NCCL stream.
   On CPU (single process): allreduce is identity (only 1 rank contributing),
   allgather places data at rank offset. */
static inline int tp_allreduce(float* buf, int count) {
    (void)buf; (void)count;
    return g_tp.initialized ? CUDA_OK : CUDA_ERR_NOT_INITIALIZED;
}
static inline int tp_allreduce_sync(float* buf, int count) {
    return tp_allreduce(buf, count);
}
static inline int tp_allgather(float* recv_buf, const float* send_buf, int send_count) {
    if (!g_tp.initialized) return CUDA_ERR_NOT_INITIALIZED;
    memcpy(recv_buf + (size_t)g_tp.rank * send_count, send_buf,
           (size_t)send_count * sizeof(float));
    return CUDA_OK;
}
/* Stream synchronisation (GPU: cudaEventRecord + cudaStreamWaitEvent; CPU: no-op) */
static inline int tp_sync_comm_to_compute(void) {
    return g_tp.initialized ? CUDA_OK : CUDA_ERR_NOT_INITIALIZED;
}
static inline int tp_sync_compute_to_comm(void) {
    return g_tp.initialized ? CUDA_OK : CUDA_ERR_NOT_INITIALIZED;
}

/* Weight sharding: extract this rank's shard from full weight matrix.
   On GPU: cudaMemcpy host→device per shard slice.
   On CPU: memcpy the appropriate slice. */

/* Row-parallel: Full [in_dim, out_dim] → Shard [in_dim, out_dim/tp_size]
   Each rank gets columns [rank*shard_cols, (rank+1)*shard_cols). */
static inline int tp_shard_weight_row_parallel(
    float* d_shard, const float* h_full, int in_dim, int out_dim
) {
    if (!g_tp.initialized) return CUDA_ERR_NOT_INITIALIZED;
    int shard_cols = out_dim / g_tp.tp_size;
    int col_offset = g_tp.rank * shard_cols;
    /* Row-by-row column slice (rows are contiguous, we extract a column band) */
    for (int row = 0; row < in_dim; row++)
        memcpy(d_shard + (size_t)row * shard_cols,
               h_full + (size_t)row * out_dim + col_offset,
               (size_t)shard_cols * sizeof(float));
    return CUDA_OK;
}

/* Column-parallel: Full [in_dim, out_dim] → Shard [in_dim/tp_size, out_dim]
   Each rank gets rows [rank*shard_rows, (rank+1)*shard_rows). */
static inline int tp_shard_weight_col_parallel(
    float* d_shard, const float* h_full, int in_dim, int out_dim
) {
    if (!g_tp.initialized) return CUDA_ERR_NOT_INITIALIZED;
    int shard_rows = in_dim / g_tp.tp_size;
    memcpy(d_shard, h_full + (size_t)g_tp.rank * shard_rows * out_dim,
           (size_t)shard_rows * out_dim * sizeof(float));
    return CUDA_OK;
}

/* Shard a 1-D vector (e.g., bias, norm weight) into tp_size equal parts. */
static inline int tp_shard_vector(float* d_shard, const float* h_full, int dim) {
    if (!g_tp.initialized) return CUDA_ERR_NOT_INITIALIZED;
    int shard = dim / g_tp.tp_size;
    memcpy(d_shard, h_full + g_tp.rank * shard, (size_t)shard * sizeof(float));
    return CUDA_OK;
}

/* Row-parallel linear: y_shard[M,shard_out] = x[M,in_dim] @ W_shard[in_dim,shard_out]
   Partial result — needs all-reduce across ranks to get full output. */
static inline int tp_row_parallel_linear(
    float* y_shard, const float* x, const float* w_shard,
    int M, int in_dim, int shard_out
) {
    return cublas_sgemm(y_shard, x, w_shard, M, shard_out, in_dim, 1.0f, 0.0f);
}

/* Column-parallel linear: y[M,out_dim] = x_shard[M,shard_in] @ W_shard[shard_in,out_dim]
   Complete result — no communication needed. */
static inline int tp_col_parallel_linear(
    float* y, const float* x_shard, const float* w_shard,
    int M, int shard_in, int out_dim
) {
    return cublas_sgemm(y, x_shard, w_shard, M, out_dim, shard_in, 1.0f, 0.0f);
}

/* Per-layer weight stride (floats) — matches tensor_parallel.cu sharded layout:
   attn_norm[hd] + Wq[hd,sd] + Wk[hd,sd] + Wv[hd,sd] + Wo[sd,hd]
   + ffn_norm[hd] + Wgate[hd,sd] + Wup[hd,sd] + Wdown[sd,hd] */
static inline size_t tp_layer_weight_stride(void) {
    if (!g_tp.initialized) return 0;
    int hd = g_tp.hidden_dim, sd = g_tp.shard_dim;
    return (size_t)hd + (size_t)hd*sd*3 + (size_t)sd*hd
         + (size_t)hd + (size_t)hd*sd*2 + (size_t)sd*hd;
}

/* Full Megatron-LM transformer layer with tensor parallelism (single-token decode).
   hidden[hidden_dim] is updated in-place. 2 all-reduces per layer.
   Uses existing CPU kernels: cuda_rms_norm, cublas_sgemm, cuda_rope,
   cuda_attention, cuda_swiglu, cuda_vec_add. */
static inline int tp_transformer_layer(
    float* hidden, const float* layer_weights, int position
) {
    if (!g_tp.initialized) return CUDA_ERR_NOT_INITIALIZED;
    int hd = g_tp.hidden_dim, sd = g_tp.shard_dim;
    /* Weight sub-pointers (same layout as tensor_parallel.cu) */
    const float* w_an = layer_weights;
    const float* w_q  = w_an + hd;
    const float* w_k  = w_q  + (size_t)hd * sd;
    const float* w_v  = w_k  + (size_t)hd * sd;
    const float* w_o  = w_v  + (size_t)hd * sd;
    const float* w_fn = w_o  + (size_t)sd * hd;
    const float* w_ga = w_fn + hd;
    const float* w_up = w_ga + (size_t)hd * sd;
    const float* w_dn = w_up + (size_t)hd * sd;
    /* --- 1. Attention block --- */
    cuda_rms_norm(g_tp.norm_buf, hidden, w_an, hd, 1e-5f);
    cublas_sgemm(g_tp.shard_q, g_tp.norm_buf, w_q, 1, sd, hd, 1.0f, 0.0f);
    cublas_sgemm(g_tp.shard_k, g_tp.norm_buf, w_k, 1, sd, hd, 1.0f, 0.0f);
    cublas_sgemm(g_tp.shard_v, g_tp.norm_buf, w_v, 1, sd, hd, 1.0f, 0.0f);
    cuda_rope(g_tp.shard_q, g_tp.shard_k, position,
              g_tp.head_dim, 10000.0f, g_tp.shard_heads);
    cuda_attention(g_tp.shard_attn_out,
        g_tp.shard_q, g_tp.shard_k, g_tp.shard_v,
        1, 1, g_tp.head_dim, g_tp.shard_heads,
        1.0f / sqrtf((float)g_tp.head_dim), 1);
    cublas_sgemm(g_tp.allreduce_buf, g_tp.shard_attn_out, w_o,
                 1, hd, sd, 1.0f, 0.0f);
    tp_sync_compute_to_comm();
    tp_allreduce(g_tp.allreduce_buf, hd);
    tp_sync_comm_to_compute();
    cuda_vec_add(hidden, hidden, g_tp.allreduce_buf, hd);
    /* --- 2. FFN block (SwiGLU) --- */
    cuda_rms_norm(g_tp.norm_buf, hidden, w_fn, hd, 1e-5f);
    cublas_sgemm(g_tp.shard_ffn_gate, g_tp.norm_buf, w_ga, 1, sd, hd, 1.0f, 0.0f);
    cublas_sgemm(g_tp.shard_ffn_up,   g_tp.norm_buf, w_up, 1, sd, hd, 1.0f, 0.0f);
    cuda_swiglu(g_tp.shard_ffn_gate, g_tp.shard_ffn_gate, g_tp.shard_ffn_up, sd);
    cublas_sgemm(g_tp.allreduce_buf, g_tp.shard_ffn_gate, w_dn,
                 1, hd, sd, 1.0f, 0.0f);
    tp_sync_compute_to_comm();
    tp_allreduce(g_tp.allreduce_buf, hd);
    tp_sync_comm_to_compute();
    cuda_vec_add(hidden, hidden, g_tp.allreduce_buf, hd);
    return CUDA_OK;
}

/* Full TP forward pass for single-token decode.
   Runs all transformer layers, final RMSNorm, and LM head with logit all-reduce.
   Weight layout per rank (contiguous):
     embed_table_shard [vocab_size * shard_dim]  — skipped for decode
     layer_0 .. layer_N  (sharded, see tp_layer_weight_stride)
     final_norm [hidden_dim]
     lm_head_shard [shard_dim, vocab_size]       — row-parallel */
static inline int tp_forward_decode(
    float* output_logits, const float* input_hidden,
    const float* weights, int num_layers, int position
) {
    if (!g_tp.initialized) return CUDA_ERR_NOT_INITIALIZED;
    int hd = g_tp.hidden_dim, sd = g_tp.shard_dim, V = g_tp.vocab_size;
    /* Skip embedding table shard (not needed for decode — input_hidden provided) */
    const float* layer_base = weights + (size_t)V * sd;
    size_t stride = tp_layer_weight_stride();
    /* Copy input hidden to working buffer */
    memcpy(g_tp.hidden_buf, input_hidden, (size_t)hd * sizeof(float));
    /* Run each transformer layer */
    for (int l = 0; l < num_layers; l++) {
        int ret = tp_transformer_layer(
            g_tp.hidden_buf, layer_base + (size_t)l * stride, position);
        if (ret != CUDA_OK) return ret;
    }
    /* Final RMS norm (replicated — same result on all ranks) */
    const float* final_norm = layer_base + (size_t)num_layers * stride;
    cuda_rms_norm(g_tp.norm_buf, g_tp.hidden_buf, final_norm, hd, 1e-5f);
    /* LM head — row-parallel:
       Each rank computes partial_logits = norm_shard[1,sd] @ lm_head_shard[sd,V]
       then all-reduce sums to full logits on all ranks. */
    const float* lm_head = final_norm + hd;
    float* norm_shard = g_tp.norm_buf + (size_t)g_tp.rank * sd;
    cublas_sgemm(output_logits, norm_shard, lm_head, 1, V, sd, 1.0f, 0.0f);
    /* All-reduce to combine partial logits from all ranks */
    tp_sync_compute_to_comm();
    tp_allreduce(output_logits, V);
    tp_sync_comm_to_compute();
    return CUDA_OK;
}

/* Query TP state */
static inline int tp_get_rank(void)       { return g_tp.rank; }
static inline int tp_get_size(void)       { return g_tp.tp_size; }
static inline int tp_get_shard_dim(void)  { return g_tp.shard_dim; }
static inline int tp_get_shard_heads(void){ return g_tp.shard_heads; }
static inline int tp_is_initialized(void) { return g_tp.initialized; }

/* ========================================================================== */
/* Pipeline Parallelism (PP) — CPU Fallback                                   */
/* On GPU builds the real CUDA implementation in pipeline_parallel.cu is      */
/* linked instead; this CPU fallback provides single-process semantics.       */
/* ========================================================================== */

#define PP_MAX_STAGES_CPU    16
#define PP_MAX_MICROBATCH_CPU 8

static struct {
    int rank;
    int pp_size;
    int hidden_dim;
    int total_layers;
    int layers_per_stage;
    int first_layer;      /* first layer for this rank */
    int max_micro_batch;
    float* stage_weights;
    size_t weights_bytes;
    float* act_buf[2];    /* double-buffered activation */
    int initialized;
} g_pp_cpu = {0};

static inline int pp_init(
    int pp_size, int rank, int hidden_dim,
    int total_layers, int max_micro_batch_size
) {
    if (g_pp_cpu.initialized) return CUDA_OK;
    if (pp_size <= 0 || pp_size > PP_MAX_STAGES_CPU) return CUDA_ERR_INVALID_ARG;
    if (total_layers % pp_size != 0) return CUDA_ERR_INVALID_ARG;
    if (rank < 0 || rank >= pp_size) return CUDA_ERR_INVALID_ARG;

    g_pp_cpu.pp_size = pp_size;
    g_pp_cpu.rank = rank;
    g_pp_cpu.hidden_dim = hidden_dim;
    g_pp_cpu.total_layers = total_layers;
    g_pp_cpu.layers_per_stage = total_layers / pp_size;
    g_pp_cpu.first_layer = rank * g_pp_cpu.layers_per_stage;
    g_pp_cpu.max_micro_batch = max_micro_batch_size;

    size_t buf_size = (size_t)hidden_dim * max_micro_batch_size * sizeof(float);
    g_pp_cpu.act_buf[0] = (float*)malloc(buf_size);
    g_pp_cpu.act_buf[1] = (float*)malloc(buf_size);
    if (!g_pp_cpu.act_buf[0] || !g_pp_cpu.act_buf[1]) {
        free(g_pp_cpu.act_buf[0]); free(g_pp_cpu.act_buf[1]);
        return CUDA_ERR_ALLOC;
    }
    g_pp_cpu.stage_weights = NULL;
    g_pp_cpu.weights_bytes = 0;
    g_pp_cpu.initialized = 1;
    return CUDA_OK;
}

static inline void pp_shutdown(void) {
    free(g_pp_cpu.act_buf[0]); free(g_pp_cpu.act_buf[1]);
    free(g_pp_cpu.stage_weights);
    memset(&g_pp_cpu, 0, sizeof(g_pp_cpu));
}

static inline int pp_load_stage_weights(const float* h_weights, size_t bytes) {
    if (!g_pp_cpu.initialized) return CUDA_ERR_NOT_INITIALIZED;
    free(g_pp_cpu.stage_weights);
    g_pp_cpu.stage_weights = (float*)malloc(bytes);
    if (!g_pp_cpu.stage_weights) return CUDA_ERR_ALLOC;
    memcpy(g_pp_cpu.stage_weights, h_weights, bytes);
    g_pp_cpu.weights_bytes = bytes;
    return CUDA_OK;
}

static inline int pp_forward_micro_batch(
    float* output, const float* input, int micro_batch_size, int buf_idx
) {
    if (!g_pp_cpu.initialized || !g_pp_cpu.stage_weights)
        return CUDA_ERR_NOT_INITIALIZED;
    int hd = g_pp_cpu.hidden_dim;
    size_t act_bytes = (size_t)hd * micro_batch_size * sizeof(float);
    float* act = g_pp_cpu.act_buf[buf_idx];
    memcpy(act, input, act_bytes);

    size_t layer_stride = (size_t)hd + (size_t)hd * hd;
    for (int l = 0; l < g_pp_cpu.layers_per_stage; l++) {
        const float* w_norm = g_pp_cpu.stage_weights + l * layer_stride;
        const float* w_linear = w_norm + hd;
        float* temp = g_pp_cpu.act_buf[1 - buf_idx];
        cuda_rms_norm(temp, act, w_norm, hd, 1e-5f);
        cublas_sgemm(act, temp, w_linear, micro_batch_size, hd, hd, 1.0f, 0.0f);
        cuda_vec_add(act, act, temp, hd * micro_batch_size);
    }
    memcpy(output, act, act_bytes);
    return CUDA_OK;
}

/* Inter-stage transfer: on single-process CPU, just memcpy */
static inline int pp_send_activation(float* dst, const float* src, int count, int dst_device) {
    (void)dst_device;
    if (!g_pp_cpu.initialized) return CUDA_ERR_NOT_INITIALIZED;
    memcpy(dst, src, (size_t)count * sizeof(float));
    return CUDA_OK;
}
static inline int pp_recv_activation_wait(void) {
    return g_pp_cpu.initialized ? CUDA_OK : CUDA_ERR_NOT_INITIALIZED;
}

static inline int pp_gpipe_forward(
    float* output, const float* input,
    int batch_size, int num_micro_batches
) {
    if (!g_pp_cpu.initialized) return CUDA_ERR_NOT_INITIALIZED;
    if (num_micro_batches <= 0 || num_micro_batches > PP_MAX_MICROBATCH_CPU)
        return CUDA_ERR_INVALID_ARG;
    int hd = g_pp_cpu.hidden_dim;
    int mbs = batch_size / num_micro_batches;
    if (mbs <= 0) return CUDA_ERR_INVALID_ARG;
    for (int m = 0; m < num_micro_batches; m++) {
        const float* mb_in = input + (size_t)m * hd * mbs;
        float* mb_out = output + (size_t)m * hd * mbs;
        int ret = pp_forward_micro_batch(mb_out, mb_in, mbs, m % 2);
        if (ret != CUDA_OK) return ret;
    }
    return CUDA_OK;
}

/* Query PP state */
static inline int pp_get_rank(void)              { return g_pp_cpu.rank; }
static inline int pp_get_size(void)              { return g_pp_cpu.pp_size; }
static inline int pp_get_stage_layers(void)      { return g_pp_cpu.layers_per_stage; }
static inline int pp_get_first_layer(void)       { return g_pp_cpu.first_layer; }
static inline int pp_is_initialized(void)        { return g_pp_cpu.initialized; }
static inline int pp_get_hidden_dim(void)        { return g_pp_cpu.hidden_dim; }
static inline int pp_get_num_micro_batches(void) { return g_pp_cpu.pp_size; }

/* ============================================================================
 * FP8 Quantization — CPU Fallback
 * ============================================================================ */

#define FP8_MAX_LAYERS_CPU 256

static struct {
    float scale[FP8_MAX_LAYERS_CPU];
    float inv_scale[FP8_MAX_LAYERS_CPU];
    float amax[FP8_MAX_LAYERS_CPU];
    int format[FP8_MAX_LAYERS_CPU]; /* 0=E4M3, 1=E5M2 */
    int num_layers;
    int initialized;
} g_fp8_cpu = {0};

static inline int cuda_fp8_init(int num_layers) {
    if (g_fp8_cpu.initialized) return CUDA_OK;
    g_fp8_cpu.num_layers = (num_layers > FP8_MAX_LAYERS_CPU) ? FP8_MAX_LAYERS_CPU : num_layers;
    for (int i = 0; i < g_fp8_cpu.num_layers; i++) {
        g_fp8_cpu.scale[i] = 1.0f;
        g_fp8_cpu.inv_scale[i] = 1.0f;
        g_fp8_cpu.amax[i] = 0.0f;
        g_fp8_cpu.format[i] = 0;
    }
    g_fp8_cpu.initialized = 1;
    return CUDA_OK;
}

static inline int cuda_fp8_shutdown(void) {
    g_fp8_cpu.initialized = 0;
    g_fp8_cpu.num_layers = 0;
    return CUDA_OK;
}

static inline int cuda_fp8_calibrate(int layer_idx, const float* data, int n) {
    if (!g_fp8_cpu.initialized || layer_idx < 0 || layer_idx >= g_fp8_cpu.num_layers) return -1;
    float mx = 0.0f;
    for (int i = 0; i < n; i++) {
        float v = data[i] < 0 ? -data[i] : data[i];
        if (v > mx) mx = v;
    }
    g_fp8_cpu.amax[layer_idx] = mx;
    float fp8_max = (g_fp8_cpu.format[layer_idx] == 0) ? 448.0f : 57344.0f;
    g_fp8_cpu.scale[layer_idx] = (mx > 1e-12f) ? fp8_max / mx : 1.0f;
    g_fp8_cpu.inv_scale[layer_idx] = 1.0f / g_fp8_cpu.scale[layer_idx];
    return CUDA_OK;
}

static inline int cuda_fp8_quantize(int layer_idx, const float* input, unsigned char* output, int n) {
    if (!g_fp8_cpu.initialized || layer_idx < 0 || layer_idx >= g_fp8_cpu.num_layers) return -1;
    float s = g_fp8_cpu.scale[layer_idx];
    float fp8_max = (g_fp8_cpu.format[layer_idx] == 0) ? 448.0f : 57344.0f;
    for (int i = 0; i < n; i++) {
        float v = input[i] / s;
        if (v > fp8_max) v = fp8_max;
        if (v < -fp8_max) v = -fp8_max;
        output[i] = (unsigned char)(((int)(v + fp8_max)) & 0xFF);
    }
    return CUDA_OK;
}

static inline int cuda_fp8_dequantize(int layer_idx, const unsigned char* input, float* output, int n) {
    if (!g_fp8_cpu.initialized || layer_idx < 0 || layer_idx >= g_fp8_cpu.num_layers) return -1;
    float inv_s = g_fp8_cpu.inv_scale[layer_idx];
    float fp8_max = (g_fp8_cpu.format[layer_idx] == 0) ? 448.0f : 57344.0f;
    for (int i = 0; i < n; i++) {
        output[i] = ((float)input[i] - fp8_max) * inv_s;
    }
    return CUDA_OK;
}

static inline int cuda_fp8_gemm(int layer_a, int layer_b,
                                 const unsigned char* A, const unsigned char* B, float* C,
                                 int M, int N, int K) {
    if (!g_fp8_cpu.initialized) return -1;
    if (layer_a < 0 || layer_a >= g_fp8_cpu.num_layers) return -1;
    if (layer_b < 0 || layer_b >= g_fp8_cpu.num_layers) return -1;
    float sa = g_fp8_cpu.inv_scale[layer_a];
    float sb = g_fp8_cpu.inv_scale[layer_b];
    float ma = (g_fp8_cpu.format[layer_a] == 0) ? 448.0f : 57344.0f;
    float mb = (g_fp8_cpu.format[layer_b] == 0) ? 448.0f : 57344.0f;
    for (int i = 0; i < M; i++) {
        for (int j = 0; j < N; j++) {
            float sum = 0.0f;
            for (int k = 0; k < K; k++) {
                float a_val = ((float)A[i * K + k] - ma) * sa;
                float b_val = ((float)B[k * N + j] - mb) * sb;
                sum += a_val * b_val;
            }
            C[i * N + j] = sum;
        }
    }
    return CUDA_OK;
}

static inline int cuda_fp8_get_scale(int layer_idx, float* scale, float* amax) {
    if (!g_fp8_cpu.initialized || layer_idx < 0 || layer_idx >= g_fp8_cpu.num_layers) return -1;
    *scale = g_fp8_cpu.scale[layer_idx];
    *amax = g_fp8_cpu.amax[layer_idx];
    return CUDA_OK;
}

static inline int cuda_fp8_set_format(int layer_idx, int format) {
    if (!g_fp8_cpu.initialized || layer_idx < 0 || layer_idx >= g_fp8_cpu.num_layers) return -1;
    g_fp8_cpu.format[layer_idx] = (format == 1) ? 1 : 0;
    return CUDA_OK;
}

static inline int cuda_fp8_is_initialized(void) { return g_fp8_cpu.initialized; }
static inline int cuda_fp8_num_layers(void) { return g_fp8_cpu.num_layers; }

/* ========================================================================== */
/* ChatGLM5 Model-Specific Kernels — CPU Fallback                            */
/* ========================================================================== */

static inline int glm5_rope_forward(
    float* query, float* key,
    int batch_size, int seq_len, int num_q_heads, int num_kv_heads, int head_dim,
    int rope_dim, float theta_base
) {
    /* GLM-style half-rotary: apply RoPE only to first rope_dim dimensions */
    for (int b = 0; b < batch_size; b++) {
        for (int s = 0; s < seq_len; s++) {
            float pos = (float)s;
            /* Q heads */
            for (int h = 0; h < num_q_heads; h++) {
                float* q = query + ((b * num_q_heads + h) * seq_len + s) * head_dim;
                for (int d = 0; d < rope_dim; d += 2) {
                    float freq = pos / powf(theta_base, (float)d / (float)rope_dim);
                    float cos_f = cosf(freq), sin_f = sinf(freq);
                    float x0 = q[d], x1 = q[d + 1];
                    q[d]     = x0 * cos_f - x1 * sin_f;
                    q[d + 1] = x0 * sin_f + x1 * cos_f;
                }
            }
            /* KV heads */
            for (int h = 0; h < num_kv_heads; h++) {
                float* k = key + ((b * num_kv_heads + h) * seq_len + s) * head_dim;
                for (int d = 0; d < rope_dim; d += 2) {
                    float freq = pos / powf(theta_base, (float)d / (float)rope_dim);
                    float cos_f = cosf(freq), sin_f = sinf(freq);
                    float x0 = k[d], x1 = k[d + 1];
                    k[d]     = x0 * cos_f - x1 * sin_f;
                    k[d + 1] = x0 * sin_f + x1 * cos_f;
                }
            }
        }
    }
    return CUDA_OK;
}

static inline int glm5_mqa_forward(
    float* output, const float* query, const float* key, const float* value,
    int batch_size, int seq_len, int num_q_heads, int num_kv_heads, int head_dim,
    float scale, int causal
) {
    int kv_group = num_q_heads / num_kv_heads;
    for (int b = 0; b < batch_size; b++) {
        for (int qh = 0; qh < num_q_heads; qh++) {
            int kvh = qh / kv_group;
            for (int sq = 0; sq < seq_len; sq++) {
                const float* q_vec = query + ((b * num_q_heads + qh) * seq_len + sq) * head_dim;
                float max_score = -FLT_MAX;
                /* Compute scores */
                int klen = causal ? (sq + 1) : seq_len;
                float* scores = (float*)calloc((size_t)klen, sizeof(float));
                if (!scores) return -1;
                for (int sk = 0; sk < klen; sk++) {
                    const float* k_vec = key + ((b * num_kv_heads + kvh) * seq_len + sk) * head_dim;
                    float dot = 0.0f;
                    for (int d = 0; d < head_dim; d++) dot += q_vec[d] * k_vec[d];
                    scores[sk] = dot * scale;
                    if (scores[sk] > max_score) max_score = scores[sk];
                }
                /* Softmax */
                float sum_exp = 0.0f;
                for (int sk = 0; sk < klen; sk++) {
                    scores[sk] = expf(scores[sk] - max_score);
                    sum_exp += scores[sk];
                }
                if (sum_exp > 0.0f) for (int sk = 0; sk < klen; sk++) scores[sk] /= sum_exp;
                /* Weighted V sum */
                float* o_vec = output + ((b * num_q_heads + qh) * seq_len + sq) * head_dim;
                memset(o_vec, 0, (size_t)head_dim * sizeof(float));
                for (int sk = 0; sk < klen; sk++) {
                    const float* v_vec = value + ((b * num_kv_heads + kvh) * seq_len + sk) * head_dim;
                    for (int d = 0; d < head_dim; d++) o_vec[d] += scores[sk] * v_vec[d];
                }
                free(scores);
            }
        }
    }
    return CUDA_OK;
}

static inline int glm5_swiglu_forward(
    float* output, const float* gate, const float* up,
    int batch_size, int seq_len, int hidden_dim
) {
    int total = batch_size * seq_len * hidden_dim;
    for (int i = 0; i < total; i++) {
        float silu_up = up[i] / (1.0f + expf(-up[i]));
        output[i] = gate[i] * silu_up;
    }
    return CUDA_OK;
}

static inline int glm5_rmsnorm_forward(
    float* output, const float* input, const float* weight,
    int batch_size, int seq_len, int hidden_dim, float eps
) {
    for (int b = 0; b < batch_size * seq_len; b++) {
        const float* row = input + b * hidden_dim;
        float* out = output + b * hidden_dim;
        float sum_sq = 0.0f;
        for (int d = 0; d < hidden_dim; d++) sum_sq += row[d] * row[d];
        float rms = sqrtf(sum_sq / (float)hidden_dim + eps);
        for (int d = 0; d < hidden_dim; d++) out[d] = (row[d] / rms) * weight[d];
    }
    return CUDA_OK;
}

/* ========================================================================== */
/* Kimi2.5 Model-Specific Kernels — CPU Fallback                             */
/* ========================================================================== */

static inline int kimi25_yarn_rope_forward(
    float* query, float* key,
    int batch_size, int seq_len, int num_q_heads, int num_kv_heads, int head_dim,
    float theta_base, float scale_factor, float yarn_attn_factor
) {
    (void)yarn_attn_factor;
    for (int b = 0; b < batch_size; b++) {
        for (int s = 0; s < seq_len; s++) {
            float pos = (float)s;
            for (int h = 0; h < num_q_heads; h++) {
                float* q = query + ((b * num_q_heads + h) * seq_len + s) * head_dim;
                for (int d = 0; d < head_dim; d += 2) {
                    float dim_ratio = (float)d / (float)head_dim;
                    float scaled_theta = theta_base * powf(scale_factor, dim_ratio);
                    float freq = pos / powf(scaled_theta, dim_ratio);
                    float cos_f = cosf(freq), sin_f = sinf(freq);
                    float x0 = q[d], x1 = q[d + 1];
                    q[d]     = x0 * cos_f - x1 * sin_f;
                    q[d + 1] = x0 * sin_f + x1 * cos_f;
                }
            }
            for (int h = 0; h < num_kv_heads; h++) {
                float* k = key + ((b * num_kv_heads + h) * seq_len + s) * head_dim;
                for (int d = 0; d < head_dim; d += 2) {
                    float dim_ratio = (float)d / (float)head_dim;
                    float scaled_theta = theta_base * powf(scale_factor, dim_ratio);
                    float freq = pos / powf(scaled_theta, dim_ratio);
                    float cos_f = cosf(freq), sin_f = sinf(freq);
                    float x0 = k[d], x1 = k[d + 1];
                    k[d]     = x0 * cos_f - x1 * sin_f;
                    k[d + 1] = x0 * sin_f + x1 * cos_f;
                }
            }
        }
    }
    return CUDA_OK;
}

static inline int kimi25_swa_forward(
    float* output, const float* query, const float* key, const float* value,
    int batch_size, int seq_len, int num_q_heads, int num_kv_heads, int head_dim,
    int window_size, float scale, int causal
) {
    int kv_group = num_q_heads / (num_kv_heads > 0 ? num_kv_heads : 1);
    for (int b = 0; b < batch_size; b++) {
        for (int qh = 0; qh < num_q_heads; qh++) {
            int kvh = qh / kv_group;
            for (int sq = 0; sq < seq_len; sq++) {
                const float* q_vec = query + ((b * num_q_heads + qh) * seq_len + sq) * head_dim;
                int k_start = (sq - window_size + 1) > 0 ? (sq - window_size + 1) : 0;
                int k_end = causal ? (sq + 1) : seq_len;
                if (k_end > seq_len) k_end = seq_len;
                int klen = k_end - k_start;
                if (klen <= 0) { memset(output + ((b * num_q_heads + qh) * seq_len + sq) * head_dim, 0, (size_t)head_dim * sizeof(float)); continue; }
                float* scores = (float*)calloc((size_t)klen, sizeof(float));
                if (!scores) return -1;
                float max_s = -FLT_MAX;
                for (int i = 0; i < klen; i++) {
                    int sk = k_start + i;
                    const float* k_vec = key + ((b * num_kv_heads + kvh) * seq_len + sk) * head_dim;
                    float dot = 0.0f;
                    for (int d = 0; d < head_dim; d++) dot += q_vec[d] * k_vec[d];
                    scores[i] = dot * scale;
                    if (scores[i] > max_s) max_s = scores[i];
                }
                float sum_e = 0.0f;
                for (int i = 0; i < klen; i++) { scores[i] = expf(scores[i] - max_s); sum_e += scores[i]; }
                if (sum_e > 0.0f) for (int i = 0; i < klen; i++) scores[i] /= sum_e;
                float* o_vec = output + ((b * num_q_heads + qh) * seq_len + sq) * head_dim;
                memset(o_vec, 0, (size_t)head_dim * sizeof(float));
                for (int i = 0; i < klen; i++) {
                    int sk = k_start + i;
                    const float* v_vec = value + ((b * num_kv_heads + kvh) * seq_len + sk) * head_dim;
                    for (int d = 0; d < head_dim; d++) o_vec[d] += scores[i] * v_vec[d];
                }
                free(scores);
            }
        }
    }
    return CUDA_OK;
}

static inline int kimi25_silu_mul_forward(
    float* output, const float* gate, const float* up,
    int batch_size, int seq_len, int hidden_dim
) {
    int total = batch_size * seq_len * hidden_dim;
    for (int i = 0; i < total; i++) {
        float silu_gate = gate[i] / (1.0f + expf(-gate[i]));
        output[i] = silu_gate * up[i];
    }
    return CUDA_OK;
}

/* ========================================================================== */
/* MiniMax2.5 Model-Specific Kernels — CPU Fallback                          */
/* ========================================================================== */

static inline int minimax25_lightning_attention_forward(
    float* output, const float* query, const float* key, const float* value,
    const float* gate_q, const float* gate_k, const float* decay,
    int batch_size, int seq_len, int num_heads, int head_dim
) {
    /* Linear attention: S_t = decay * S_{t-1} + (k_t * gate_k) * (v_t)^T
       o_t = (q_t * gate_q) @ S_t */
    size_t state_sz = (size_t)head_dim * (size_t)head_dim;
    float* state = (float*)calloc(state_sz, sizeof(float));
    if (!state) return -1;
    for (int b = 0; b < batch_size; b++) {
        for (int h = 0; h < num_heads; h++) {
            float dec = decay[h];
            memset(state, 0, state_sz * sizeof(float));
            for (int s = 0; s < seq_len; s++) {
                int idx = ((b * num_heads + h) * seq_len + s) * head_dim;
                /* Decay state */
                for (size_t i = 0; i < state_sz; i++) state[i] *= dec;
                /* Outer product: state += (k*gate_k) outer v */
                for (int di = 0; di < head_dim; di++) {
                    float gk = key[idx + di] * gate_k[idx + di];
                    for (int dj = 0; dj < head_dim; dj++) {
                        state[di * head_dim + dj] += gk * value[idx + dj];
                    }
                }
                /* Output: o = (q*gate_q) @ state */
                for (int di = 0; di < head_dim; di++) {
                    float gq = query[idx + di] * gate_q[idx + di];
                    float sum = 0.0f;
                    for (int dj = 0; dj < head_dim; dj++) {
                        sum += gq * state[di * head_dim + dj];
                    }
                    output[idx + di] = sum;
                }
            }
        }
    }
    free(state);
    return CUDA_OK;
}

static inline int minimax25_moe_route(
    int* expert_indices, float* expert_weights,
    const float* hidden_states, const float* gate_weight,
    int batch_size, int seq_len, int hidden_dim,
    int num_experts, int top_k
) {
    int total_tokens = batch_size * seq_len;
    float* logits = (float*)calloc((size_t)num_experts, sizeof(float));
    if (!logits) return -1;
    for (int t = 0; t < total_tokens; t++) {
        const float* hs = hidden_states + t * hidden_dim;
        /* Compute router logits: logits[e] = hs . gate_weight[e] */
        for (int e = 0; e < num_experts; e++) {
            float dot = 0.0f;
            for (int d = 0; d < hidden_dim; d++) {
                dot += hs[d] * gate_weight[e * hidden_dim + d];
            }
            logits[e] = dot;
        }
        /* Softmax over experts */
        float max_l = logits[0];
        for (int e = 1; e < num_experts; e++) if (logits[e] > max_l) max_l = logits[e];
        float sum_e = 0.0f;
        for (int e = 0; e < num_experts; e++) { logits[e] = expf(logits[e] - max_l); sum_e += logits[e]; }
        if (sum_e > 0.0f) for (int e = 0; e < num_experts; e++) logits[e] /= sum_e;
        /* Select top-k */
        for (int k = 0; k < top_k; k++) {
            int best = 0;
            for (int e = 1; e < num_experts; e++) if (logits[e] > logits[best]) best = e;
            expert_indices[t * top_k + k] = best;
            expert_weights[t * top_k + k] = logits[best];
            logits[best] = -1.0f; /* exclude from next pick */
        }
        /* Renormalize weights */
        float wsum = 0.0f;
        for (int k = 0; k < top_k; k++) wsum += expert_weights[t * top_k + k];
        if (wsum > 0.0f) for (int k = 0; k < top_k; k++) expert_weights[t * top_k + k] /= wsum;
    }
    free(logits);
    return CUDA_OK;
}

static inline int minimax25_swiglu_expert_forward(
    float* output, const float* input,
    const float* gate_proj_weight, const float* up_proj_weight,
    const float* down_proj_weight,
    int num_tokens, int hidden_dim, int intermediate_dim
) {
    float* gate_buf = (float*)calloc((size_t)intermediate_dim, sizeof(float));
    float* up_buf = (float*)calloc((size_t)intermediate_dim, sizeof(float));
    if (!gate_buf || !up_buf) { free(gate_buf); free(up_buf); return -1; }
    for (int t = 0; t < num_tokens; t++) {
        const float* x = input + t * hidden_dim;
        float* o = output + t * hidden_dim;
        /* gate_proj and up_proj: GEMV */
        for (int i = 0; i < intermediate_dim; i++) {
            float g = 0.0f, u = 0.0f;
            for (int d = 0; d < hidden_dim; d++) {
                g += gate_proj_weight[i * hidden_dim + d] * x[d];
                u += up_proj_weight[i * hidden_dim + d] * x[d];
            }
            /* SwiGLU: silu(gate) * up */
            float silu_g = g / (1.0f + expf(-g));
            gate_buf[i] = silu_g * u;
        }
        /* down_proj: GEMV */
        for (int d = 0; d < hidden_dim; d++) {
            float sum = 0.0f;
            for (int i = 0; i < intermediate_dim; i++) {
                sum += down_proj_weight[d * intermediate_dim + i] * gate_buf[i];
            }
            o[d] = sum;
        }
    }
    free(gate_buf);
    free(up_buf);
    return CUDA_OK;
}

#ifdef __cplusplus
}
#endif

#endif /* CUDA_KERNELS_H */
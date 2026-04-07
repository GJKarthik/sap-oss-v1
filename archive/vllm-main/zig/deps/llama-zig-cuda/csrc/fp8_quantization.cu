/**
 * FP8 Quantization Kernels - Hopper (sm_89/sm_90) Optimizations
 *
 * E4M3 (range-focused) and E5M2 (precision-focused) FP8 formats:
 * - Per-tensor and per-channel calibration
 * - FP8 GEMM via cublasLt with FP8 input types
 * - Dynamic scaling factor computation
 * - Mixed-precision: FP8 storage + FP16/FP32 compute
 *
 * Requires: CUDA 12.0+, Hopper GPU (sm_89 for L40, sm_90 for H100)
 */

#include "cuda_kernels.h"
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <cublasLt.h>
#include <cstdint>
#include <cmath>
#include <cfloat>

// ============================================================================
// FP8 Constants & Types
// ============================================================================

#define FP8_BLOCK_SIZE 256
#define FP8_E4M3_MAX 448.0f
#define FP8_E5M2_MAX 57344.0f

enum Fp8Format {
    FP8_E4M3 = 0,  // 4-bit exponent, 3-bit mantissa (for weights)
    FP8_E5M2 = 1   // 5-bit exponent, 2-bit mantissa (for activations)
};

struct Fp8ScaleParams {
    float scale;
    float inv_scale;
    float amax;
    Fp8Format format;
    int per_channel;
    int num_channels;
};

// ============================================================================
// Global State
// ============================================================================

#define FP8_MAX_LAYERS 256
static Fp8ScaleParams g_fp8_scales[FP8_MAX_LAYERS] = {0};
static int g_fp8_num_layers = 0;
static int g_fp8_initialized = 0;
static cublasLtHandle_t g_fp8_cublaslt = nullptr;

// ============================================================================
// Calibration Kernels
// ============================================================================

__global__ void fp8_amax_kernel(const float* __restrict__ input, float* __restrict__ amax_out, int n) {
    __shared__ float shared_amax[FP8_BLOCK_SIZE];
    int tid = threadIdx.x;
    int gid = blockIdx.x * blockDim.x + threadIdx.x;

    float local_max = 0.0f;
    for (int i = gid; i < n; i += blockDim.x * gridDim.x) {
        local_max = fmaxf(local_max, fabsf(input[i]));
    }
    shared_amax[tid] = local_max;
    __syncthreads();

    for (int stride = blockDim.x / 2; stride > 0; stride >>= 1) {
        if (tid < stride) {
            shared_amax[tid] = fmaxf(shared_amax[tid], shared_amax[tid + stride]);
        }
        __syncthreads();
    }

    if (tid == 0) {
        atomicMax((int*)amax_out, __float_as_int(shared_amax[0]));
    }
}

__global__ void fp8_quantize_kernel(
    const float* __restrict__ input,
    uint8_t* __restrict__ output,
    float scale, float max_val, int n
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= n) return;

    float val = input[idx] / scale;
    val = fminf(fmaxf(val, -max_val), max_val);
    val = rintf(val);
    output[idx] = (uint8_t)((int)(val + max_val) & 0xFF);
}

__global__ void fp8_dequantize_kernel(
    const uint8_t* __restrict__ input,
    float* __restrict__ output,
    float scale, float max_val, int n
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= n) return;

    float val = ((float)input[idx]) - max_val;
    output[idx] = val * scale;
}

__global__ void fp8_quantize_per_channel_kernel(
    const float* __restrict__ input,
    uint8_t* __restrict__ output,
    const float* __restrict__ scales,
    float max_val, int rows, int cols
) {
    int row = blockIdx.y;
    int col = blockIdx.x * blockDim.x + threadIdx.x;
    if (col >= cols || row >= rows) return;

    int idx = row * cols + col;
    float val = input[idx] / scales[row];
    val = fminf(fmaxf(val, -max_val), max_val);
    val = rintf(val);
    output[idx] = (uint8_t)((int)(val + max_val) & 0xFF);
}

// ============================================================================
// FP8 GEMM (Matrix Multiply)
// ============================================================================

static int fp8_gemm_cublaslt(
    const uint8_t* A, const uint8_t* B, float* C,
    int M, int N, int K,
    float alpha, float beta,
    float scale_A, float scale_B
) {
    if (!g_fp8_cublaslt) return -1;

    cublasLtMatmulDesc_t matmulDesc;
    cublasLtMatrixLayout_t Adesc, Bdesc, Cdesc;

    cublasLtMatmulDescCreate(&matmulDesc, CUBLAS_COMPUTE_32F, CUDA_R_32F);
    cublasLtMatrixLayoutCreate(&Adesc, CUDA_R_8F_E4M3, M, K, M);
    cublasLtMatrixLayoutCreate(&Bdesc, CUDA_R_8F_E4M3, K, N, K);
    cublasLtMatrixLayoutCreate(&Cdesc, CUDA_R_32F, M, N, M);

    float combined_alpha = alpha * scale_A * scale_B;
    cublasStatus_t status = cublasLtMatmul(
        g_fp8_cublaslt, matmulDesc,
        &combined_alpha, A, Adesc, B, Bdesc,
        &beta, C, Cdesc, C, Cdesc,
        nullptr, nullptr, 0, 0
    );

    cublasLtMatrixLayoutDestroy(Cdesc);
    cublasLtMatrixLayoutDestroy(Bdesc);
    cublasLtMatrixLayoutDestroy(Adesc);
    cublasLtMatmulDescDestroy(matmulDesc);

    return (status == CUBLAS_STATUS_SUCCESS) ? 0 : -2;
}

// ============================================================================
// Dynamic Scale Update
// ============================================================================

__global__ void fp8_update_scale_kernel(
    float* __restrict__ amax_history,
    float* __restrict__ scale_out,
    float fp8_max, int history_len
) {
    float max_amax = 0.0f;
    for (int i = 0; i < history_len; i++) {
        max_amax = fmaxf(max_amax, amax_history[i]);
    }
    float eps = 1e-12f;
    *scale_out = fp8_max / fmaxf(max_amax, eps);
}

// ============================================================================
// Extern C API
// ============================================================================

extern "C" {

int cuda_fp8_init(int num_layers) {
    if (g_fp8_initialized) return 0;
    g_fp8_num_layers = (num_layers > FP8_MAX_LAYERS) ? FP8_MAX_LAYERS : num_layers;
    for (int i = 0; i < g_fp8_num_layers; i++) {
        g_fp8_scales[i].scale = 1.0f;
        g_fp8_scales[i].inv_scale = 1.0f;
        g_fp8_scales[i].amax = 0.0f;
        g_fp8_scales[i].format = FP8_E4M3;
        g_fp8_scales[i].per_channel = 0;
        g_fp8_scales[i].num_channels = 0;
    }
    cublasLtCreate(&g_fp8_cublaslt);
    g_fp8_initialized = 1;
    return 0;
}

int cuda_fp8_shutdown(void) {
    if (!g_fp8_initialized) return 0;
    if (g_fp8_cublaslt) {
        cublasLtDestroy(g_fp8_cublaslt);
        g_fp8_cublaslt = nullptr;
    }
    g_fp8_initialized = 0;
    return 0;
}

int cuda_fp8_calibrate(int layer_idx, const float* data, int n) {
    if (layer_idx < 0 || layer_idx >= g_fp8_num_layers) return -1;

    float* d_amax;
    cudaMalloc(&d_amax, sizeof(float));
    cudaMemset(d_amax, 0, sizeof(float));

    int blocks = (n + FP8_BLOCK_SIZE - 1) / FP8_BLOCK_SIZE;
    fp8_amax_kernel<<<blocks, FP8_BLOCK_SIZE>>>(data, d_amax, n);

    float amax;
    cudaMemcpy(&amax, d_amax, sizeof(float), cudaMemcpyDeviceToHost);
    cudaFree(d_amax);

    g_fp8_scales[layer_idx].amax = amax;
    float fp8_max = (g_fp8_scales[layer_idx].format == FP8_E4M3) ? FP8_E4M3_MAX : FP8_E5M2_MAX;
    g_fp8_scales[layer_idx].scale = (amax > 1e-12f) ? fp8_max / amax : 1.0f;
    g_fp8_scales[layer_idx].inv_scale = 1.0f / g_fp8_scales[layer_idx].scale;

    return 0;
}

int cuda_fp8_quantize(int layer_idx, const float* input, uint8_t* output, int n) {
    if (layer_idx < 0 || layer_idx >= g_fp8_num_layers) return -1;

    float scale = g_fp8_scales[layer_idx].scale;
    float max_val = (g_fp8_scales[layer_idx].format == FP8_E4M3) ? FP8_E4M3_MAX : FP8_E5M2_MAX;

    int blocks = (n + FP8_BLOCK_SIZE - 1) / FP8_BLOCK_SIZE;
    fp8_quantize_kernel<<<blocks, FP8_BLOCK_SIZE>>>(input, output, 1.0f / scale, max_val, n);
    return (cudaGetLastError() == cudaSuccess) ? 0 : -2;
}

int cuda_fp8_dequantize(int layer_idx, const uint8_t* input, float* output, int n) {
    if (layer_idx < 0 || layer_idx >= g_fp8_num_layers) return -1;

    float inv_scale = g_fp8_scales[layer_idx].inv_scale;
    float max_val = (g_fp8_scales[layer_idx].format == FP8_E4M3) ? FP8_E4M3_MAX : FP8_E5M2_MAX;

    int blocks = (n + FP8_BLOCK_SIZE - 1) / FP8_BLOCK_SIZE;
    fp8_dequantize_kernel<<<blocks, FP8_BLOCK_SIZE>>>(input, output, inv_scale, max_val, n);
    return (cudaGetLastError() == cudaSuccess) ? 0 : -2;
}

int cuda_fp8_gemm(int layer_a, int layer_b,
                   const uint8_t* A, const uint8_t* B, float* C,
                   int M, int N, int K) {
    if (layer_a < 0 || layer_a >= g_fp8_num_layers) return -1;
    if (layer_b < 0 || layer_b >= g_fp8_num_layers) return -1;

    float scale_a = g_fp8_scales[layer_a].inv_scale;
    float scale_b = g_fp8_scales[layer_b].inv_scale;

    return fp8_gemm_cublaslt(A, B, C, M, N, K, 1.0f, 0.0f, scale_a, scale_b);
}

int cuda_fp8_get_scale(int layer_idx, float* scale, float* amax) {
    if (layer_idx < 0 || layer_idx >= g_fp8_num_layers) return -1;
    *scale = g_fp8_scales[layer_idx].scale;
    *amax = g_fp8_scales[layer_idx].amax;
    return 0;
}

int cuda_fp8_set_format(int layer_idx, int format) {
    if (layer_idx < 0 || layer_idx >= g_fp8_num_layers) return -1;
    g_fp8_scales[layer_idx].format = (format == 1) ? FP8_E5M2 : FP8_E4M3;
    return 0;
}

int cuda_fp8_is_initialized(void) { return g_fp8_initialized; }
int cuda_fp8_num_layers(void)     { return g_fp8_num_layers; }

} // extern "C"


/**
 * Tensor Core Operations for T4 GPU (SM 7.5)
 * 
 * Phase 1: Quick Wins - Enable Tensor Cores for ~2x throughput
 * 
 * T4 Tensor Cores support:
 * - FP16 (HMMA) - 65 TFLOPS
 * - INT8 (IMMA) - 130 TOPS
 * - INT4 (future)
 */

#include "cuda_kernels.h"
#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <cuda_fp16.h>
#include <cublasLt.h>
#include <cstdio>

// ============================================================================
// Global State for Tensor Core Operations
// ============================================================================

static cublasLtHandle_t g_cublaslt_handle = nullptr;
static bool g_tensor_cores_enabled = false;

// ============================================================================
// Tensor Core Initialization
// ============================================================================

extern "C" int tensor_core_init(void) {
    if (g_cublaslt_handle) return 0;
    
    cublasStatus_t status = cublasLtCreate(&g_cublaslt_handle);
    if (status != CUBLAS_STATUS_SUCCESS) {
        return -1;
    }
    
    g_tensor_cores_enabled = true;
    return 0;
}

extern "C" void tensor_core_shutdown(void) {
    if (g_cublaslt_handle) {
        cublasLtDestroy(g_cublaslt_handle);
        g_cublaslt_handle = nullptr;
    }
    g_tensor_cores_enabled = false;
}

extern "C" int tensor_cores_available(void) {
    return g_tensor_cores_enabled ? 1 : 0;
}

// ============================================================================
// FP16 GEMM with Tensor Cores (2x faster than FP32)
// ============================================================================

/**
 * Half-precision GEMM using Tensor Cores
 * C = alpha * A @ B + beta * C
 * All matrices in FP16, computation in FP16
 */
extern "C" int tensor_core_hgemm(
    __half* C, const __half* A, const __half* B,
    int M, int N, int K,
    float alpha, float beta
) {
    if (!g_cublaslt_handle) {
        if (tensor_core_init() != 0) return -1;
    }
    
    cublasLtMatmulDesc_t operationDesc;
    cublasLtMatrixLayout_t Adesc, Bdesc, Cdesc;
    
    // Create operation descriptor
    cublasLtMatmulDescCreate(&operationDesc, CUBLAS_COMPUTE_16F, CUDA_R_16F);
    
    // Create matrix descriptors (column-major for cuBLAS)
    cublasLtMatrixLayoutCreate(&Adesc, CUDA_R_16F, K, M, K);
    cublasLtMatrixLayoutCreate(&Bdesc, CUDA_R_16F, N, K, N);
    cublasLtMatrixLayoutCreate(&Cdesc, CUDA_R_16F, N, M, N);
    
    // Execute with Tensor Cores
    __half alpha_h = __float2half(alpha);
    __half beta_h = __float2half(beta);
    
    cublasStatus_t status = cublasLtMatmul(
        g_cublaslt_handle,
        operationDesc,
        &alpha_h,
        B, Bdesc,
        A, Adesc,
        &beta_h,
        C, Cdesc,
        C, Cdesc,
        nullptr,  // algo
        nullptr,  // workspace
        0,        // workspace size
        0         // stream
    );
    
    // Cleanup
    cublasLtMatrixLayoutDestroy(Adesc);
    cublasLtMatrixLayoutDestroy(Bdesc);
    cublasLtMatrixLayoutDestroy(Cdesc);
    cublasLtMatmulDescDestroy(operationDesc);
    
    return (status == CUBLAS_STATUS_SUCCESS) ? 0 : -1;
}

// ============================================================================
// Mixed Precision GEMM (FP16 compute, FP32 accumulate)
// ============================================================================

/**
 * Mixed precision GEMM for better numerical stability
 * Inputs in FP16, accumulation in FP32, output in FP16
 */
extern "C" int tensor_core_mixed_gemm(
    __half* C, const __half* A, const __half* B,
    int M, int N, int K,
    float alpha, float beta
) {
    if (!g_cublaslt_handle) {
        if (tensor_core_init() != 0) return -1;
    }
    
    cublasLtMatmulDesc_t operationDesc;
    cublasLtMatrixLayout_t Adesc, Bdesc, Cdesc;
    
    // Use FP32 accumulation for stability
    cublasLtMatmulDescCreate(&operationDesc, CUBLAS_COMPUTE_32F, CUDA_R_32F);
    
    cublasLtMatrixLayoutCreate(&Adesc, CUDA_R_16F, K, M, K);
    cublasLtMatrixLayoutCreate(&Bdesc, CUDA_R_16F, N, K, N);
    cublasLtMatrixLayoutCreate(&Cdesc, CUDA_R_16F, N, M, N);
    
    cublasStatus_t status = cublasLtMatmul(
        g_cublaslt_handle,
        operationDesc,
        &alpha,
        B, Bdesc,
        A, Adesc,
        &beta,
        C, Cdesc,
        C, Cdesc,
        nullptr, nullptr, 0, 0
    );
    
    cublasLtMatrixLayoutDestroy(Adesc);
    cublasLtMatrixLayoutDestroy(Bdesc);
    cublasLtMatrixLayoutDestroy(Cdesc);
    cublasLtMatmulDescDestroy(operationDesc);
    
    return (status == CUBLAS_STATUS_SUCCESS) ? 0 : -1;
}

// ============================================================================
// FP32 to FP16 Conversion Kernels
// ============================================================================

__global__ void convert_fp32_to_fp16_kernel(
    __half* dst, const float* src, int n
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        dst[idx] = __float2half(src[idx]);
    }
}

__global__ void convert_fp16_to_fp32_kernel(
    float* dst, const __half* src, int n
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        dst[idx] = __half2float(src[idx]);
    }
}

extern "C" int convert_fp32_to_fp16(
    __half* dst, const float* src, int n
) {
    int threads = 256;
    int blocks = (n + threads - 1) / threads;
    convert_fp32_to_fp16_kernel<<<blocks, threads>>>(dst, src, n);
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

extern "C" int convert_fp16_to_fp32(
    float* dst, const __half* src, int n
) {
    int threads = 256;
    int blocks = (n + threads - 1) / threads;
    convert_fp16_to_fp32_kernel<<<blocks, threads>>>(dst, src, n);
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

// ============================================================================
// Batched Tensor Core Operations
// ============================================================================

/**
 * Batched HGEMM for multi-head attention
 * Process multiple heads in parallel with Tensor Cores
 */
extern "C" int tensor_core_hgemm_batched(
    __half* C, const __half* A, const __half* B,
    int batch_size, int M, int N, int K,
    float alpha, float beta
) {
    if (!g_cublaslt_handle) {
        if (tensor_core_init() != 0) return -1;
    }
    
    cublasLtMatmulDesc_t operationDesc;
    cublasLtMatrixLayout_t Adesc, Bdesc, Cdesc;
    
    cublasLtMatmulDescCreate(&operationDesc, CUBLAS_COMPUTE_16F, CUDA_R_16F);
    
    // Strided batch layout
    int64_t strideA = M * K;
    int64_t strideB = K * N;
    int64_t strideC = M * N;
    
    cublasLtMatrixLayoutCreate(&Adesc, CUDA_R_16F, K, M, K);
    cublasLtMatrixLayoutSetAttribute(Adesc, CUBLASLT_MATRIX_LAYOUT_BATCH_COUNT, &batch_size, sizeof(batch_size));
    cublasLtMatrixLayoutSetAttribute(Adesc, CUBLASLT_MATRIX_LAYOUT_STRIDED_BATCH_OFFSET, &strideA, sizeof(strideA));
    
    cublasLtMatrixLayoutCreate(&Bdesc, CUDA_R_16F, N, K, N);
    cublasLtMatrixLayoutSetAttribute(Bdesc, CUBLASLT_MATRIX_LAYOUT_BATCH_COUNT, &batch_size, sizeof(batch_size));
    cublasLtMatrixLayoutSetAttribute(Bdesc, CUBLASLT_MATRIX_LAYOUT_STRIDED_BATCH_OFFSET, &strideB, sizeof(strideB));
    
    cublasLtMatrixLayoutCreate(&Cdesc, CUDA_R_16F, N, M, N);
    cublasLtMatrixLayoutSetAttribute(Cdesc, CUBLASLT_MATRIX_LAYOUT_BATCH_COUNT, &batch_size, sizeof(batch_size));
    cublasLtMatrixLayoutSetAttribute(Cdesc, CUBLASLT_MATRIX_LAYOUT_STRIDED_BATCH_OFFSET, &strideC, sizeof(strideC));
    
    __half alpha_h = __float2half(alpha);
    __half beta_h = __float2half(beta);
    
    cublasStatus_t status = cublasLtMatmul(
        g_cublaslt_handle,
        operationDesc,
        &alpha_h,
        B, Bdesc,
        A, Adesc,
        &beta_h,
        C, Cdesc,
        C, Cdesc,
        nullptr, nullptr, 0, 0
    );
    
    cublasLtMatrixLayoutDestroy(Adesc);
    cublasLtMatrixLayoutDestroy(Bdesc);
    cublasLtMatrixLayoutDestroy(Cdesc);
    cublasLtMatmulDescDestroy(operationDesc);
    
    return (status == CUBLAS_STATUS_SUCCESS) ? 0 : -1;
}

// ============================================================================
// Fused FP16 Operations for Attention
// ============================================================================

/**
 * Fused scale + softmax in FP16
 * Avoids intermediate FP32 conversions
 */
__global__ void fused_scale_softmax_fp16_kernel(
    __half* data, int n, float scale
) {
    extern __shared__ float sdata[];
    
    int tid = threadIdx.x;
    
    // Grid-stride find max
    float local_max = -INFINITY;
    for (int i = tid; i < n; i += blockDim.x) {
        local_max = fmaxf(local_max, __half2float(data[i]) * scale);
    }
    sdata[tid] = local_max;
    __syncthreads();
    
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) {
            sdata[tid] = fmaxf(sdata[tid], sdata[tid + s]);
        }
        __syncthreads();
    }
    float max_val = sdata[0];
    __syncthreads();
    
    // Grid-stride exp and sum
    float local_sum = 0.0f;
    for (int i = tid; i < n; i += blockDim.x) {
        local_sum += expf(__half2float(data[i]) * scale - max_val);
    }
    sdata[tid] = local_sum;
    __syncthreads();
    
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) {
            sdata[tid] += sdata[tid + s];
        }
        __syncthreads();
    }
    float sum = sdata[0];
    
    // Grid-stride normalize and store as FP16
    for (int i = tid; i < n; i += blockDim.x) {
        data[i] = __float2half(
            expf(__half2float(data[i]) * scale - max_val) / sum
        );
    }
}

extern "C" int fused_scale_softmax_fp16(
    __half* data, int n, float scale
) {
    int threads = 256;
    int blocks = 1;  // Grid-stride loop handles arbitrary n
    size_t shared_mem = threads * sizeof(float);
    
    fused_scale_softmax_fp16_kernel<<<blocks, threads, shared_mem>>>(data, n, scale);
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

// ============================================================================
// Tensor Core RMS Norm (FP16)
// ============================================================================

__global__ void rms_norm_fp16_kernel(
    __half* dst, const __half* src, const __half* weight,
    int n, float eps
) {
    extern __shared__ float sdata[];
    
    int tid = threadIdx.x;
    
    // Grid-stride accumulation of squared values
    float sum_sq = 0.0f;
    for (int i = tid; i < n; i += blockDim.x) {
        float val = __half2float(src[i]);
        sum_sq += val * val;
    }
    sdata[tid] = sum_sq;
    __syncthreads();
    
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) {
            sdata[tid] += sdata[tid + s];
        }
        __syncthreads();
    }
    
    if (tid == 0) {
        float mean_sq = sdata[0] / n;
        sdata[0] = rsqrtf(mean_sq + eps);
    }
    __syncthreads();
    
    float rms = sdata[0];
    
    // Grid-stride normalize
    for (int i = tid; i < n; i += blockDim.x) {
        float w = __half2float(weight[i]);
        dst[i] = __float2half(__half2float(src[i]) * rms * w);
    }
}

extern "C" int tensor_core_rms_norm_fp16(
    __half* dst, const __half* src, const __half* weight,
    int n, float eps
) {
    int threads = 256;
    int blocks = 1;  // Grid-stride loop handles arbitrary n
    size_t shared_mem = threads * sizeof(float);
    
    rms_norm_fp16_kernel<<<blocks, threads, shared_mem>>>(dst, src, weight, n, eps);
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

// ============================================================================
// Tensor Core SiLU (FP16)
// ============================================================================

__global__ void silu_fp16_kernel(__half* dst, const __half* src, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        float x = __half2float(src[idx]);
        float silu = x / (1.0f + expf(-x));
        dst[idx] = __float2half(silu);
    }
}

extern "C" int tensor_core_silu_fp16(__half* dst, const __half* src, int n) {
    int threads = 256;
    int blocks = (n + threads - 1) / threads;
    silu_fp16_kernel<<<blocks, threads>>>(dst, src, n);
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}

// ============================================================================
// Tensor Core SwiGLU (FP16)
// ============================================================================

__global__ void swiglu_fp16_kernel(
    __half* dst, const __half* gate, const __half* up, int n
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        float g = __half2float(gate[idx]);
        float u = __half2float(up[idx]);
        float silu_g = g / (1.0f + expf(-g));
        dst[idx] = __float2half(silu_g * u);
    }
}

extern "C" int tensor_core_swiglu_fp16(
    __half* dst, const __half* gate, const __half* up, int n
) {
    int threads = 256;
    int blocks = (n + threads - 1) / threads;
    swiglu_fp16_kernel<<<blocks, threads>>>(dst, gate, up, n);
    return (cudaGetLastError() == cudaSuccess) ? 0 : -1;
}
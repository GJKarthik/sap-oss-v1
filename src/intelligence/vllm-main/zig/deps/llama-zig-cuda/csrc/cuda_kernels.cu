/**
 * CUDA Kernels Implementation for Zig llama
 * 
 * GPU-accelerated kernels for LLM inference using CUDA and cuBLAS.
 * Compile with: nvcc -O3 -arch=sm_75 -lcublas cuda_kernels.cu -o libcuda_kernels.so --shared
 */

#include "cuda_kernels.h"
#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <cuda_fp16.h>
#include <cmath>
#include <cstdio>

// ============================================================================
// Global State
// ============================================================================

static bool g_cuda_initialized = false;
static cublasHandle_t g_cublas_handle = nullptr;
static char g_last_error[256] = {0};
static int g_last_error_code = 0;  // CUDA_OK

// ============================================================================
// Error Handling
// ============================================================================

#define CUDA_CHECK(call) do { \
    cudaError_t err = call; \
    if (err != cudaSuccess) { \
        snprintf(g_last_error, sizeof(g_last_error), "CUDA error: %s", cudaGetErrorString(err)); \
        return -1; \
    } \
} while(0)

#define CUBLAS_CHECK(call) do { \
    cublasStatus_t status = call; \
    if (status != CUBLAS_STATUS_SUCCESS) { \
        snprintf(g_last_error, sizeof(g_last_error), "cuBLAS error: %d", status); \
        return -1; \
    } \
} while(0)

// ============================================================================
// Initialization & Device Management
// ============================================================================

extern "C" int cuda_init(void) {
    if (g_cuda_initialized) return 0;
    
    int device_count;
    cudaError_t err = cudaGetDeviceCount(&device_count);
    if (err != cudaSuccess || device_count == 0) {
        snprintf(g_last_error, sizeof(g_last_error), "No CUDA devices found");
        return -1;
    }
    
    CUDA_CHECK(cudaSetDevice(0));
    g_cuda_initialized = true;
    return 0;
}

extern "C" void cuda_shutdown(void) {
    if (g_cublas_handle) {
        cublasDestroy(g_cublas_handle);
        g_cublas_handle = nullptr;
    }
    cudaDeviceReset();
    g_cuda_initialized = false;
}

extern "C" int cuda_is_available(void) {
    return g_cuda_initialized ? 1 : 0;
}

extern "C" int cuda_get_device_info(CudaDeviceInfo* info) {
    if (!g_cuda_initialized) return -1;
    
    cudaDeviceProp prop;
    CUDA_CHECK(cudaGetDeviceProperties(&prop, 0));
    
    strncpy(info->name, prop.name, sizeof(info->name) - 1);
    info->total_memory = prop.totalGlobalMem;
    
    size_t free_mem, total_mem;
    CUDA_CHECK(cudaMemGetInfo(&free_mem, &total_mem));
    info->free_memory = free_mem;
    
    info->compute_capability_major = prop.major;
    info->compute_capability_minor = prop.minor;
    info->multiprocessor_count = prop.multiProcessorCount;
    info->max_threads_per_block = prop.maxThreadsPerBlock;
    
    return 0;
}

// ============================================================================
// GPU Capability Detection & Fallback Routing
// ============================================================================

struct GpuCapabilities {
    int sm_version;           // e.g. 75 for SM 7.5
    bool has_tensor_cores;    // SM >= 7.0 (Volta+)
    bool has_fp16_arithmetic; // SM >= 5.3
    bool has_int8_tensor;     // SM >= 7.5 (Turing+) for INT8 Tensor Core GEMM
    bool has_bf16;            // SM >= 8.0 (Ampere+)
    bool has_extended_smem;   // SM >= 8.0 (>48KB configurable smem)
    size_t max_smem_per_block;
    int num_sms;
    bool initialized;
};

static GpuCapabilities g_gpu_caps = {0};

/**
 * Detect GPU capabilities once. Thread-safe via initialized flag.
 * Called automatically by capability query functions.
 */
static void detect_gpu_capabilities(void) {
    if (g_gpu_caps.initialized) return;

    cudaDeviceProp prop;
    if (cudaGetDeviceProperties(&prop, 0) != cudaSuccess) {
        // No GPU — all capabilities false
        g_gpu_caps.initialized = true;
        return;
    }

    int sm = prop.major * 10 + prop.minor;
    g_gpu_caps.sm_version         = sm;
    g_gpu_caps.has_tensor_cores   = (sm >= 70);
    g_gpu_caps.has_fp16_arithmetic = (sm >= 53);
    g_gpu_caps.has_int8_tensor    = (sm >= 75);
    g_gpu_caps.has_bf16           = (sm >= 80);
    g_gpu_caps.has_extended_smem  = (sm >= 80);
    g_gpu_caps.num_sms            = prop.multiProcessorCount;
    g_gpu_caps.max_smem_per_block = (prop.sharedMemPerBlockOptin > 0)
                                     ? prop.sharedMemPerBlockOptin
                                     : prop.sharedMemPerBlock;
    g_gpu_caps.initialized = true;
}

/**
 * Query whether Tensor Cores are available on the current device.
 * @return 1 if Tensor Cores available, 0 otherwise.
 */
extern "C" int cuda_has_tensor_cores(void) {
    detect_gpu_capabilities();
    return g_gpu_caps.has_tensor_cores ? 1 : 0;
}

/**
 * Query whether FP16 arithmetic is natively supported.
 * @return 1 if FP16 arithmetic supported, 0 otherwise.
 */
extern "C" int cuda_has_fp16(void) {
    detect_gpu_capabilities();
    return g_gpu_caps.has_fp16_arithmetic ? 1 : 0;
}

/**
 * Query whether INT8 Tensor Core operations are supported (Turing+).
 * @return 1 if INT8 TC supported, 0 otherwise.
 */
extern "C" int cuda_has_int8_tensor(void) {
    detect_gpu_capabilities();
    return g_gpu_caps.has_int8_tensor ? 1 : 0;
}

/**
 * Query full GPU capability flags.
 * @param sm_version     Output: SM version (e.g. 75).
 * @param has_tc         Output: 1 if Tensor Cores available.
 * @param has_fp16       Output: 1 if FP16 arithmetic.
 * @param has_int8_tc    Output: 1 if INT8 Tensor Core.
 * @param has_bf16       Output: 1 if BF16 supported.
 * @return 0 on success.
 */
extern "C" int cuda_get_capabilities(
    int* sm_version, int* has_tc, int* has_fp16,
    int* has_int8_tc, int* has_bf16
) {
    detect_gpu_capabilities();
    if (sm_version) *sm_version = g_gpu_caps.sm_version;
    if (has_tc)     *has_tc     = g_gpu_caps.has_tensor_cores ? 1 : 0;
    if (has_fp16)   *has_fp16   = g_gpu_caps.has_fp16_arithmetic ? 1 : 0;
    if (has_int8_tc)*has_int8_tc= g_gpu_caps.has_int8_tensor ? 1 : 0;
    if (has_bf16)   *has_bf16   = g_gpu_caps.has_bf16 ? 1 : 0;
    return 0;
}

// ============================================================================
// Memory Management
// ============================================================================

extern "C" void* cuda_malloc(size_t size) {
    void* ptr = nullptr;
    cudaError_t err = cudaMalloc(&ptr, size);
    if (err != cudaSuccess) {
        snprintf(g_last_error, sizeof(g_last_error), "cudaMalloc failed: %s", cudaGetErrorString(err));
        return nullptr;
    }
    return ptr;
}

extern "C" void cuda_free(void* ptr) {
    if (ptr) cudaFree(ptr);
}

extern "C" int cuda_memcpy_h2d(void* dst, const void* src, size_t size) {
    CUDA_CHECK(cudaMemcpy(dst, src, size, cudaMemcpyHostToDevice));
    return 0;
}

extern "C" int cuda_memcpy_d2h(void* dst, const void* src, size_t size) {
    CUDA_CHECK(cudaMemcpy(dst, src, size, cudaMemcpyDeviceToHost));
    return 0;
}

extern "C" int cuda_memcpy_d2d(void* dst, const void* src, size_t size) {
    CUDA_CHECK(cudaMemcpy(dst, src, size, cudaMemcpyDeviceToDevice));
    return 0;
}

extern "C" int cuda_memset(void* ptr, int value, size_t size) {
    CUDA_CHECK(cudaMemset(ptr, value, size));
    return 0;
}

// ============================================================================
// cuBLAS Operations
// ============================================================================

extern "C" int cublas_init(void) {
    if (g_cublas_handle) return 0;
    CUBLAS_CHECK(cublasCreate(&g_cublas_handle));
    return 0;
}

extern "C" void cublas_shutdown(void) {
    if (g_cublas_handle) {
        cublasDestroy(g_cublas_handle);
        g_cublas_handle = nullptr;
    }
}

// SGEMM: C = alpha * A @ B + beta * C (row-major)
extern "C" int cublas_sgemm(
    float* C, const float* A, const float* B,
    int M, int N, int K,
    float alpha, float beta
) {
    if (!g_cublas_handle) {
        if (cublas_init() != 0) return -1;
    }
    
    // cuBLAS uses column-major, so we compute C^T = B^T @ A^T
    // which gives us C in row-major
    CUBLAS_CHECK(cublasSgemm(
        g_cublas_handle,
        CUBLAS_OP_N, CUBLAS_OP_N,
        N, M, K,
        &alpha,
        B, N,
        A, K,
        &beta,
        C, N
    ));
    return 0;
}

// SGEMV: y = alpha * A @ x + beta * y
extern "C" int cublas_sgemv(
    float* y, const float* A, const float* x,
    int M, int K,
    float alpha, float beta
) {
    if (!g_cublas_handle) {
        if (cublas_init() != 0) return -1;
    }
    
    // For row-major A, use transposed operation
    CUBLAS_CHECK(cublasSgemv(
        g_cublas_handle,
        CUBLAS_OP_T,
        K, M,
        &alpha,
        A, K,
        x, 1,
        &beta,
        y, 1
    ));
    return 0;
}

// SGEMM with B transposed: C[M,N] = alpha * A[M,K] @ B[N,K]^T + beta * C[M,N]
// B is stored row-major as [N,K]; the transpose gives [K,N].
extern "C" int cublas_sgemm_transB(
    float* C, const float* A, const float* B,
    int M, int N, int K,
    float alpha, float beta
) {
    if (!g_cublas_handle) {
        if (cublas_init() != 0) return -1;
    }
    
    // Row-major trick: C^T[N,M] = B[N,K]_cm^T @ A^T_cm[K,M]
    // B_cm (column-major view of row-major B[N,K]) = B^T[K,N]
    // We need B itself [N,K], so transpose the cm view: CUBLAS_OP_T
    // A_cm (column-major view of row-major A[M,K]) = A^T[K,M] → CUBLAS_OP_N
    CUBLAS_CHECK(cublasSgemm(
        g_cublas_handle,
        CUBLAS_OP_T, CUBLAS_OP_N,
        N, M, K,
        &alpha,
        B, K,
        A, K,
        &beta,
        C, N
    ));
    return 0;
}

// Batched SGEMM for multi-head attention
extern "C" int cublas_sgemm_batched(
    float* C, const float* A, const float* B,
    int batch_size, int M, int N, int K,
    float alpha, float beta
) {
    if (!g_cublas_handle) {
        if (cublas_init() != 0) return -1;
    }
    
    int64_t strideA = M * K;
    int64_t strideB = K * N;
    int64_t strideC = M * N;
    
    CUBLAS_CHECK(cublasSgemmStridedBatched(
        g_cublas_handle,
        CUBLAS_OP_N, CUBLAS_OP_N,
        N, M, K,
        &alpha,
        B, N, strideB,
        A, K, strideA,
        &beta,
        C, N, strideC,
        batch_size
    ));
    return 0;
}

// ============================================================================
// CUDA Kernels
// ============================================================================

// SiLU kernel: x * sigmoid(x)
__global__ void __launch_bounds__(256)
silu_kernel(float* __restrict__ dst, const float* __restrict__ src, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        float x = __ldg(&src[idx]);
        dst[idx] = x / (1.0f + expf(-x));
    }
}

extern "C" int cuda_silu(float* dst, const float* src, int n) {
    if (!dst || !src) { g_last_error_code = CUDA_ERR_INVALID_ARG; return CUDA_ERR_INVALID_ARG; }
    if (n <= 0) return CUDA_OK;
    int threads = 256;
    int blocks = (n + threads - 1) / threads;
    silu_kernel<<<blocks, threads>>>(dst, src, n);
    CUDA_CHECK(cudaGetLastError());
    return 0;
}

extern "C" int cuda_silu_inplace(float* data, int n) {
    return cuda_silu(data, data, n);
}

// GELU kernel
__global__ void __launch_bounds__(256)
gelu_kernel(float* __restrict__ dst, const float* __restrict__ src, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        float x = __ldg(&src[idx]);
        float cdf = 0.5f * (1.0f + tanhf(0.7978845608f * (x + 0.044715f * x * x * x)));
        dst[idx] = x * cdf;
    }
}

extern "C" int cuda_gelu(float* dst, const float* src, int n) {
    int threads = 256;
    int blocks = (n + threads - 1) / threads;
    gelu_kernel<<<blocks, threads>>>(dst, src, n);
    CUDA_CHECK(cudaGetLastError());
    return 0;
}

// ReLU kernel
__global__ void __launch_bounds__(256)
relu_kernel(float* __restrict__ dst, const float* __restrict__ src, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        dst[idx] = fmaxf(__ldg(&src[idx]), 0.0f);
    }
}

extern "C" int cuda_relu(float* dst, const float* src, int n) {
    int threads = 256;
    int blocks = (n + threads - 1) / threads;
    relu_kernel<<<blocks, threads>>>(dst, src, n);
    CUDA_CHECK(cudaGetLastError());
    return 0;
}

// Vector addition
__global__ void __launch_bounds__(256)
vec_add_kernel(float* __restrict__ dst, const float* __restrict__ a, const float* __restrict__ b, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        dst[idx] = __ldg(&a[idx]) + __ldg(&b[idx]);
    }
}

extern "C" int cuda_vec_add(float* dst, const float* a, const float* b, int n) {
    if (!dst || !a || !b) { g_last_error_code = CUDA_ERR_INVALID_ARG; return CUDA_ERR_INVALID_ARG; }
    if (n <= 0) return CUDA_OK;
    int threads = 256;
    int blocks = (n + threads - 1) / threads;
    vec_add_kernel<<<blocks, threads>>>(dst, a, b, n);
    CUDA_CHECK(cudaGetLastError());
    return 0;
}

// Vector multiplication
__global__ void __launch_bounds__(256)
vec_mul_kernel(float* __restrict__ dst, const float* __restrict__ a, const float* __restrict__ b, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        dst[idx] = __ldg(&a[idx]) * __ldg(&b[idx]);
    }
}

extern "C" int cuda_vec_mul(float* dst, const float* a, const float* b, int n) {
    int threads = 256;
    int blocks = (n + threads - 1) / threads;
    vec_mul_kernel<<<blocks, threads>>>(dst, a, b, n);
    CUDA_CHECK(cudaGetLastError());
    return 0;
}

// Vector scale
__global__ void __launch_bounds__(256)
vec_scale_kernel(float* __restrict__ dst, const float* __restrict__ src, float scale, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        dst[idx] = __ldg(&src[idx]) * scale;
    }
}

extern "C" int cuda_vec_scale(float* dst, const float* src, float scale, int n) {
    int threads = 256;
    int blocks = (n + threads - 1) / threads;
    vec_scale_kernel<<<blocks, threads>>>(dst, src, scale, n);
    CUDA_CHECK(cudaGetLastError());
    return 0;
}

// Fused multiply-add
__global__ void __launch_bounds__(256)
vec_fma_kernel(float* __restrict__ dst, const float* __restrict__ a,
               const float* __restrict__ b, const float* __restrict__ c, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        dst[idx] = fmaf(__ldg(&a[idx]), __ldg(&b[idx]), __ldg(&c[idx]));
    }
}

extern "C" int cuda_vec_fma(float* dst, const float* a, const float* b, const float* c, int n) {
    int threads = 256;
    int blocks = (n + threads - 1) / threads;
    vec_fma_kernel<<<blocks, threads>>>(dst, a, b, c, n);
    CUDA_CHECK(cudaGetLastError());
    return 0;
}

// SwiGLU: silu(gate) * up
__global__ void __launch_bounds__(256)
swiglu_kernel(float* __restrict__ dst, const float* __restrict__ gate,
              const float* __restrict__ up, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        float g = __ldg(&gate[idx]);
        float silu_g = g / (1.0f + expf(-g));
        dst[idx] = silu_g * __ldg(&up[idx]);
    }
}

extern "C" int cuda_swiglu(float* dst, const float* gate, const float* up, int n) {
    int threads = 256;
    int blocks = (n + threads - 1) / threads;
    swiglu_kernel<<<blocks, threads>>>(dst, gate, up, n);
    CUDA_CHECK(cudaGetLastError());
    return 0;
}

// ============================================================================
// RMS Normalization
// ============================================================================

__global__ void __launch_bounds__(256)
rms_norm_kernel(
    float* __restrict__ dst, const float* __restrict__ src,
    const float* __restrict__ weight, int n, float eps
) {
    extern __shared__ float sdata[];
    
    int tid = threadIdx.x;
    
    // Grid-stride accumulation of squared values
    float sum_sq = 0.0f;
    for (int i = tid; i < n; i += blockDim.x) {
        float val = src[i];
        sum_sq += val * val;
    }
    
    sdata[tid] = sum_sq;
    __syncthreads();
    
    // Block reduction
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
    
    // Normalize with grid-stride loop
    for (int i = tid; i < n; i += blockDim.x) {
        dst[i] = src[i] * rms * weight[i];
    }
}

extern "C" int cuda_rms_norm(
    float* dst, const float* src, const float* weight,
    int n, float eps
) {
    if (!dst || !src || !weight) { g_last_error_code = CUDA_ERR_INVALID_ARG; return CUDA_ERR_INVALID_ARG; }
    if (n <= 0) { g_last_error_code = CUDA_ERR_INVALID_ARG; return CUDA_ERR_INVALID_ARG; }
    int threads = 256;
    int blocks = 1;  // One block per row; grid-stride loop handles arbitrary n
    size_t shared_mem = threads * sizeof(float);
    
    rms_norm_kernel<<<blocks, threads, shared_mem>>>(dst, src, weight, n, eps);
    CUDA_CHECK(cudaGetLastError());
    return 0;
}

extern "C" int cuda_rms_norm_batched(
    float* dst, const float* src, const float* weight,
    int batch_size, int n, float eps
) {
    for (int i = 0; i < batch_size; i++) {
        int ret = cuda_rms_norm(
            dst + i * n,
            src + i * n,
            weight,
            n, eps
        );
        if (ret != 0) return ret;
    }
    return 0;
}

// ============================================================================
// Softmax
// ============================================================================

__global__ void __launch_bounds__(256)
softmax_kernel(float* __restrict__ data, int n) {
    extern __shared__ float sdata[];
    
    int tid = threadIdx.x;
    
    // Grid-stride find max
    float local_max = -INFINITY;
    for (int i = tid; i < n; i += blockDim.x) {
        local_max = fmaxf(local_max, data[i]);
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
        local_sum += expf(data[i] - max_val);
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
    
    // Grid-stride normalize
    for (int i = tid; i < n; i += blockDim.x) {
        data[i] = expf(data[i] - max_val) / sum;
    }
}

extern "C" int cuda_softmax(float* data, int n) {
    if (!data) { g_last_error_code = CUDA_ERR_INVALID_ARG; return CUDA_ERR_INVALID_ARG; }
    if (n <= 0) return CUDA_OK;
    int threads = 256;
    int blocks = 1;  // One block per row; grid-stride loop handles arbitrary n
    size_t shared_mem = threads * sizeof(float);
    
    softmax_kernel<<<blocks, threads, shared_mem>>>(data, n);
    CUDA_CHECK(cudaGetLastError());
    return 0;
}

extern "C" int cuda_softmax_batched(float* data, int batch_size, int n) {
    for (int i = 0; i < batch_size; i++) {
        int ret = cuda_softmax(data + i * n, n);
        if (ret != 0) return ret;
    }
    return 0;
}

// ============================================================================
// Reductions
// ============================================================================

__global__ void __launch_bounds__(256)
reduce_sum_kernel(float* __restrict__ result, const float* __restrict__ data, int n) {
    extern __shared__ float sdata[];
    
    int tid = threadIdx.x;
    
    // Grid-stride accumulation
    float acc = 0.0f;
    for (int i = tid; i < n; i += blockDim.x) {
        acc += data[i];
    }
    sdata[tid] = acc;
    __syncthreads();
    
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) {
            sdata[tid] += sdata[tid + s];
        }
        __syncthreads();
    }
    
    if (tid == 0) {
        *result = sdata[0];
    }
}

extern "C" int cuda_sum(float* result, const float* data, int n) {
    int threads = 256;
    int blocks = 1;  // Grid-stride loop handles arbitrary n
    size_t shared_mem = threads * sizeof(float);
    
    reduce_sum_kernel<<<blocks, threads, shared_mem>>>(result, data, n);
    CUDA_CHECK(cudaGetLastError());
    return 0;
}

__global__ void __launch_bounds__(256)
reduce_max_kernel(float* __restrict__ result, const float* __restrict__ data, int n) {
    extern __shared__ float sdata[];
    
    int tid = threadIdx.x;
    
    // Grid-stride accumulation
    float local_max = -INFINITY;
    for (int i = tid; i < n; i += blockDim.x) {
        local_max = fmaxf(local_max, data[i]);
    }
    sdata[tid] = local_max;
    __syncthreads();
    
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) {
            sdata[tid] = fmaxf(sdata[tid], sdata[tid + s]);
        }
        __syncthreads();
    }
    
    if (tid == 0) {
        *result = sdata[0];
    }
}

extern "C" int cuda_max(float* result, const float* data, int n) {
    int threads = 256;
    int blocks = 1;  // Grid-stride loop handles arbitrary n
    size_t shared_mem = threads * sizeof(float);
    
    reduce_max_kernel<<<blocks, threads, shared_mem>>>(result, data, n);
    CUDA_CHECK(cudaGetLastError());
    return 0;
}

// Dot product using cuBLAS
extern "C" int cuda_dot(float* result, const float* a, const float* b, int n) {
    if (!g_cublas_handle) {
        if (cublas_init() != 0) return -1;
    }
    CUBLAS_CHECK(cublasSdot(g_cublas_handle, n, a, 1, b, 1, result));
    return 0;
}

// ============================================================================
// RoPE (Rotary Position Embedding)
// ============================================================================

__global__ void __launch_bounds__(128)
rope_kernel(
    float* __restrict__ q, float* __restrict__ k,
    int pos, int head_dim, float base_freq,
    int batch_size
) {
    int batch_idx = blockIdx.y;
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    int half_dim = head_dim / 2;
    
    if (batch_idx >= batch_size || idx >= half_dim) return;
    
    float freq = 1.0f / powf(base_freq, (float)(2 * idx) / (float)head_dim);
    float theta = (float)pos * freq;
    float cos_t = cosf(theta);
    float sin_t = sinf(theta);
    
    int offset = batch_idx * head_dim;
    
    // Rotate query
    float q0 = q[offset + 2 * idx];
    float q1 = q[offset + 2 * idx + 1];
    q[offset + 2 * idx] = q0 * cos_t - q1 * sin_t;
    q[offset + 2 * idx + 1] = q0 * sin_t + q1 * cos_t;
    
    // Rotate key
    float k0 = k[offset + 2 * idx];
    float k1 = k[offset + 2 * idx + 1];
    k[offset + 2 * idx] = k0 * cos_t - k1 * sin_t;
    k[offset + 2 * idx + 1] = k0 * sin_t + k1 * cos_t;
}

extern "C" int cuda_rope(
    float* q, float* k,
    int pos, int head_dim, float base_freq,
    int batch_size
) {
    if (!q || !k) { g_last_error_code = CUDA_ERR_INVALID_ARG; return CUDA_ERR_INVALID_ARG; }
    if (head_dim <= 0 || head_dim % 2 != 0 || batch_size <= 0) {
        g_last_error_code = CUDA_ERR_INVALID_ARG; return CUDA_ERR_INVALID_ARG;
    }
    int half_dim = head_dim / 2;
    int threads = 128;
    int blocks_x = (half_dim + threads - 1) / threads;
    dim3 grid(blocks_x, batch_size);
    
    rope_kernel<<<grid, threads>>>(
        q, k, pos, head_dim, base_freq, batch_size
    );
    CUDA_CHECK(cudaGetLastError());
    return 0;
}

// ============================================================================
// Layer Normalization
// ============================================================================

/**
 * Full Layer Normalization kernel.
 *
 * For each element i in [0, n):
 *   mean     = (1/n) * sum(src[j], j=0..n-1)
 *   var      = (1/n) * sum((src[j] - mean)^2, j=0..n-1)
 *   x_hat_i  = (src[i] - mean) / sqrt(var + eps)
 *   dst[i]   = weight[i] * x_hat_i + bias[i]
 *
 * If bias is NULL, the additive bias term is skipped.
 * Uses a single thread-block with grid-stride loops and shared-memory
 * reductions (two passes: one for mean, one for variance).
 */
__global__ void __launch_bounds__(256)
layer_norm_kernel(
    float* __restrict__ dst, const float* __restrict__ src,
    const float* __restrict__ weight, const float* __restrict__ bias,
    int n, float eps
) {
    extern __shared__ float sdata[];

    int tid = threadIdx.x;

    // --- Pass 1: compute mean ---
    float local_sum = 0.0f;
    for (int i = tid; i < n; i += blockDim.x) {
        local_sum += src[i];
    }
    sdata[tid] = local_sum;
    __syncthreads();

    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) sdata[tid] += sdata[tid + s];
        __syncthreads();
    }
    float mean = sdata[0] / (float)n;
    __syncthreads();

    // --- Pass 2: compute variance ---
    float local_var = 0.0f;
    for (int i = tid; i < n; i += blockDim.x) {
        float diff = src[i] - mean;
        local_var += diff * diff;
    }
    sdata[tid] = local_var;
    __syncthreads();

    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) sdata[tid] += sdata[tid + s];
        __syncthreads();
    }
    float inv_std = rsqrtf(sdata[0] / (float)n + eps);
    __syncthreads();

    // --- Pass 3: normalize + affine ---
    for (int i = tid; i < n; i += blockDim.x) {
        float x_hat = (src[i] - mean) * inv_std;
        dst[i] = weight[i] * x_hat + (bias ? bias[i] : 0.0f);
    }
}

extern "C" int cuda_layer_norm(
    float* dst, const float* src,
    const float* weight, const float* bias,
    int n, float eps
) {
    if (!dst || !src || !weight) {
        g_last_error_code = CUDA_ERR_INVALID_ARG;
        return CUDA_ERR_INVALID_ARG;
    }
    if (n <= 0) {
        g_last_error_code = CUDA_ERR_INVALID_ARG;
        return CUDA_ERR_INVALID_ARG;
    }

    int threads = 256;
    size_t shared_mem = threads * sizeof(float);
    layer_norm_kernel<<<1, threads, shared_mem>>>(dst, src, weight, bias, n, eps);
    CUDA_CHECK(cudaGetLastError());
    return 0;
}

// ============================================================================
// Quantization
// ============================================================================

// Q8_0 block: 1 f16 scale + 32 int8 values
struct BlockQ8_0 {
    __half d;
    int8_t qs[32];
};

__global__ void dequant_q8_0_kernel(float* dst, const BlockQ8_0* src, int num_blocks) {
    int block_idx = blockIdx.x;
    int val_idx = threadIdx.x;
    
    if (block_idx >= num_blocks || val_idx >= 32) return;
    
    float scale = __half2float(src[block_idx].d);
    int dst_idx = block_idx * 32 + val_idx;
    dst[dst_idx] = (float)src[block_idx].qs[val_idx] * scale;
}

extern "C" int cuda_dequant_q8_0(float* dst, const void* src, int num_blocks) {
    dequant_q8_0_kernel<<<num_blocks, 32>>>(dst, (const BlockQ8_0*)src, num_blocks);
    CUDA_CHECK(cudaGetLastError());
    return 0;
}

// Q4_0 block: 1 f16 scale + 16 bytes (32 values, 4 bits each)
struct BlockQ4_0 {
    __half d;
    uint8_t qs[16];
};

__global__ void dequant_q4_0_kernel(float* dst, const BlockQ4_0* src, int num_blocks) {
    int block_idx = blockIdx.x;
    int byte_idx = threadIdx.x / 2;
    int nibble = threadIdx.x % 2;
    
    if (block_idx >= num_blocks || threadIdx.x >= 32) return;
    
    float scale = __half2float(src[block_idx].d);
    uint8_t byte = src[block_idx].qs[byte_idx];
    int8_t val = nibble == 0 ? (byte & 0x0F) : (byte >> 4);
    val -= 8; // Center around 0
    
    int dst_idx = block_idx * 32 + threadIdx.x;
    dst[dst_idx] = (float)val * scale;
}

extern "C" int cuda_dequant_q4_0(float* dst, const void* src, int num_blocks) {
    dequant_q4_0_kernel<<<num_blocks, 32>>>(dst, (const BlockQ4_0*)src, num_blocks);
    CUDA_CHECK(cudaGetLastError());
    return 0;
}

extern "C" int cuda_matvec_q8_0(
    float* y, const void* A_q8, const float* x,
    int M, int K
) {
    // Dequantize to temp buffer, then use cuBLAS
    int num_blocks = (M * K + 31) / 32;
    float* A_f32;
    CUDA_CHECK(cudaMalloc(&A_f32, M * K * sizeof(float)));
    
    int ret = cuda_dequant_q8_0(A_f32, A_q8, num_blocks);
    if (ret != 0) {
        cudaFree(A_f32);
        return ret;
    }
    
    ret = cublas_sgemv(y, A_f32, x, M, K, 1.0f, 0.0f);
    cudaFree(A_f32);
    return ret;
}

// ============================================================================
// Attention (simplified)
// ============================================================================

extern "C" int cuda_attention(
    float* output,
    const float* Q, const float* K, const float* V,
    int batch_size, int seq_len, int head_dim, int num_heads,
    float scale, int causal
) {
    if (!output || !Q || !K || !V) { g_last_error_code = CUDA_ERR_INVALID_ARG; return CUDA_ERR_INVALID_ARG; }
    if (batch_size <= 0 || seq_len <= 0 || head_dim <= 0 || num_heads <= 0) {
        g_last_error_code = CUDA_ERR_INVALID_ARG; return CUDA_ERR_INVALID_ARG;
    }
    // Simplified attention: Q @ K^T @ V
    // For production, would use flash attention
    
    int qk_size = seq_len * seq_len;
    float* scores;
    CUDA_CHECK(cudaMalloc(&scores, batch_size * num_heads * qk_size * sizeof(float)));
    
    // Q @ K^T for each head
    for (int b = 0; b < batch_size * num_heads; b++) {
        int offset = b * seq_len * head_dim;
        cublas_sgemm(
            scores + b * qk_size,
            Q + offset, K + offset,
            seq_len, seq_len, head_dim,
            scale, 0.0f
        );
    }
    
    // Softmax
    cuda_softmax_batched(scores, batch_size * num_heads * seq_len, seq_len);
    
    // Scores @ V
    for (int b = 0; b < batch_size * num_heads; b++) {
        int offset = b * seq_len * head_dim;
        cublas_sgemm(
            output + offset,
            scores + b * qk_size, V + offset,
            seq_len, head_dim, seq_len,
            1.0f, 0.0f
        );
    }
    
    cudaFree(scores);
    return 0;
}

// ============================================================================
// Synchronization & Error Handling
// ============================================================================

extern "C" int cuda_synchronize(void) {
    CUDA_CHECK(cudaDeviceSynchronize());
    return 0;
}

extern "C" const char* cuda_get_last_error(void) {
    return g_last_error;
}

extern "C" int cuda_get_last_error_code(void) {
    return g_last_error_code;
}

extern "C" const char* cuda_error_string(int error_code) {
    switch (error_code) {
        case  0: return "Success";
        case -1: return "CUDA not initialized; call cuda_init() first";
        case -2: return "No CUDA-capable device found";
        case -3: return "Device memory allocation failed";
        case -4: return "Memory copy failed";
        case -5: return "Kernel launch or execution failed";
        case -6: return "cuBLAS operation failed";
        case -7: return "Invalid argument (null pointer, bad dimension, etc.)";
        case -8: return "Index or size out of valid range";
        case -9: return "CUDA graph capture/launch/update failed";
        case -10: return "Operation not supported on this device";
        default: return "Unknown error";
    }
}
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
__global__ void silu_kernel(float* dst, const float* src, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        float x = src[idx];
        dst[idx] = x / (1.0f + expf(-x));
    }
}

extern "C" int cuda_silu(float* dst, const float* src, int n) {
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
__global__ void gelu_kernel(float* dst, const float* src, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        float x = src[idx];
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
__global__ void relu_kernel(float* dst, const float* src, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        dst[idx] = fmaxf(src[idx], 0.0f);
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
__global__ void vec_add_kernel(float* dst, const float* a, const float* b, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        dst[idx] = a[idx] + b[idx];
    }
}

extern "C" int cuda_vec_add(float* dst, const float* a, const float* b, int n) {
    int threads = 256;
    int blocks = (n + threads - 1) / threads;
    vec_add_kernel<<<blocks, threads>>>(dst, a, b, n);
    CUDA_CHECK(cudaGetLastError());
    return 0;
}

// Vector multiplication
__global__ void vec_mul_kernel(float* dst, const float* a, const float* b, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        dst[idx] = a[idx] * b[idx];
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
__global__ void vec_scale_kernel(float* dst, const float* src, float scale, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        dst[idx] = src[idx] * scale;
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
__global__ void vec_fma_kernel(float* dst, const float* a, const float* b, const float* c, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        dst[idx] = fmaf(a[idx], b[idx], c[idx]);
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
__global__ void swiglu_kernel(float* dst, const float* gate, const float* up, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        float g = gate[idx];
        float silu_g = g / (1.0f + expf(-g));
        dst[idx] = silu_g * up[idx];
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

__global__ void rms_norm_kernel(
    float* dst, const float* src, const float* weight,
    int n, float eps
) {
    // Shared memory for reduction
    extern __shared__ float sdata[];
    
    int tid = threadIdx.x;
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    
    // Load and compute squared values
    float val = (idx < n) ? src[idx] : 0.0f;
    sdata[tid] = val * val;
    __syncthreads();
    
    // Reduction to compute sum of squares
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) {
            sdata[tid] += sdata[tid + s];
        }
        __syncthreads();
    }
    
    // Compute RMS and normalize
    if (tid == 0) {
        float mean_sq = sdata[0] / n;
        float rms = rsqrtf(mean_sq + eps);
        // Store RMS for use by other threads
        sdata[0] = rms;
    }
    __syncthreads();
    
    float rms = sdata[0];
    if (idx < n) {
        dst[idx] = src[idx] * rms * weight[idx];
    }
}

extern "C" int cuda_rms_norm(
    float* dst, const float* src, const float* weight,
    int n, float eps
) {
    int threads = 256;
    int blocks = 1; // Single block for now (works for typical hidden dims)
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

__global__ void softmax_kernel(float* data, int n) {
    extern __shared__ float sdata[];
    
    int tid = threadIdx.x;
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    
    // Load data and find max
    float val = (idx < n) ? data[idx] : -INFINITY;
    sdata[tid] = val;
    __syncthreads();
    
    // Reduce to find max
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) {
            sdata[tid] = fmaxf(sdata[tid], sdata[tid + s]);
        }
        __syncthreads();
    }
    float max_val = sdata[0];
    __syncthreads();
    
    // Compute exp(x - max) and sum
    val = (idx < n) ? expf(data[idx] - max_val) : 0.0f;
    sdata[tid] = val;
    __syncthreads();
    
    // Reduce to find sum
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) {
            sdata[tid] += sdata[tid + s];
        }
        __syncthreads();
    }
    float sum = sdata[0];
    
    // Normalize
    if (idx < n) {
        data[idx] = expf(data[idx] - max_val) / sum;
    }
}

extern "C" int cuda_softmax(float* data, int n) {
    int threads = 256;
    int blocks = 1;
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

__global__ void reduce_sum_kernel(float* result, const float* data, int n) {
    extern __shared__ float sdata[];
    
    int tid = threadIdx.x;
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    
    sdata[tid] = (idx < n) ? data[idx] : 0.0f;
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
    int blocks = 1;
    size_t shared_mem = threads * sizeof(float);
    
    reduce_sum_kernel<<<blocks, threads, shared_mem>>>(result, data, n);
    CUDA_CHECK(cudaGetLastError());
    return 0;
}

__global__ void reduce_max_kernel(float* result, const float* data, int n) {
    extern __shared__ float sdata[];
    
    int tid = threadIdx.x;
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    
    sdata[tid] = (idx < n) ? data[idx] : -INFINITY;
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
    int blocks = 1;
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

__global__ void rope_kernel(
    float* q, float* k,
    int pos, int head_dim, float base_freq,
    int total_elements
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    int half_dim = head_dim / 2;
    
    if (idx >= half_dim) return;
    
    float freq = 1.0f / powf(base_freq, (float)(2 * idx) / (float)head_dim);
    float theta = (float)pos * freq;
    float cos_t = cosf(theta);
    float sin_t = sinf(theta);
    
    // Rotate query
    float q0 = q[2 * idx];
    float q1 = q[2 * idx + 1];
    q[2 * idx] = q0 * cos_t - q1 * sin_t;
    q[2 * idx + 1] = q0 * sin_t + q1 * cos_t;
    
    // Rotate key
    float k0 = k[2 * idx];
    float k1 = k[2 * idx + 1];
    k[2 * idx] = k0 * cos_t - k1 * sin_t;
    k[2 * idx + 1] = k0 * sin_t + k1 * cos_t;
}

extern "C" int cuda_rope(
    float* q, float* k,
    int pos, int head_dim, float base_freq,
    int batch_size
) {
    int half_dim = head_dim / 2;
    int threads = 128;
    int blocks = (half_dim + threads - 1) / threads;
    
    for (int b = 0; b < batch_size; b++) {
        rope_kernel<<<blocks, threads>>>(
            q + b * head_dim,
            k + b * head_dim,
            pos, head_dim, base_freq, half_dim
        );
    }
    CUDA_CHECK(cudaGetLastError());
    return 0;
}

// ============================================================================
// Layer Normalization
// ============================================================================

extern "C" int cuda_layer_norm(
    float* dst, const float* src,
    const float* weight, const float* bias,
    int n, float eps
) {
    // First compute mean
    float* d_mean;
    float* d_var;
    CUDA_CHECK(cudaMalloc(&d_mean, sizeof(float)));
    CUDA_CHECK(cudaMalloc(&d_var, sizeof(float)));
    
    cuda_sum(d_mean, src, n);
    
    float h_mean;
    CUDA_CHECK(cudaMemcpy(&h_mean, d_mean, sizeof(float), cudaMemcpyDeviceToHost));
    h_mean /= n;
    
    // TODO: Complete layer norm implementation
    // For now, delegate to RMS norm as approximation
    cuda_free(d_mean);
    cuda_free(d_var);
    
    return cuda_rms_norm(dst, src, weight, n, eps);
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
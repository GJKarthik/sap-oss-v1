/**
 * CUDA Kernels for Zig llama
 * 
 * C header for Zig FFI bindings to CUDA/cuBLAS operations.
 * Provides GPU-accelerated kernels for LLM inference.
 */

#ifndef CUDA_KERNELS_H
#define CUDA_KERNELS_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Initialization & Device Management
// ============================================================================

/**
 * Initialize CUDA context and check for GPU availability.
 * Returns: 0 on success, -1 if no CUDA device available.
 */
int cuda_init(void);

/**
 * Shutdown CUDA context and free resources.
 */
void cuda_shutdown(void);

/**
 * Check if CUDA is available and initialized.
 */
int cuda_is_available(void);

/**
 * Get device properties.
 */
typedef struct {
    char name[256];
    size_t total_memory;
    size_t free_memory;
    int compute_capability_major;
    int compute_capability_minor;
    int multiprocessor_count;
    int max_threads_per_block;
} CudaDeviceInfo;

int cuda_get_device_info(CudaDeviceInfo* info);

// ============================================================================
// Memory Management
// ============================================================================

/**
 * Allocate GPU memory.
 * Returns: pointer to device memory, or NULL on failure.
 */
void* cuda_malloc(size_t size);

/**
 * Free GPU memory.
 */
void cuda_free(void* ptr);

/**
 * Copy data from host to device.
 */
int cuda_memcpy_h2d(void* dst, const void* src, size_t size);

/**
 * Copy data from device to host.
 */
int cuda_memcpy_d2h(void* dst, const void* src, size_t size);

/**
 * Copy data device to device.
 */
int cuda_memcpy_d2d(void* dst, const void* src, size_t size);

/**
 * Set device memory to value.
 */
int cuda_memset(void* ptr, int value, size_t size);

// ============================================================================
// cuBLAS Matrix Operations
// ============================================================================

/**
 * Initialize cuBLAS handle.
 */
int cublas_init(void);

/**
 * Shutdown cuBLAS.
 */
void cublas_shutdown(void);

/**
 * SGEMM: C = alpha * A @ B + beta * C
 * A: [M, K], B: [K, N], C: [M, N]
 * Row-major layout assumed, internally transposed for cuBLAS column-major.
 */
int cublas_sgemm(
    float* C, const float* A, const float* B,
    int M, int N, int K,
    float alpha, float beta
);

/**
 * SGEMV: y = alpha * A @ x + beta * y
 * A: [M, K], x: [K], y: [M]
 */
int cublas_sgemv(
    float* y, const float* A, const float* x,
    int M, int K,
    float alpha, float beta
);

/**
 * Batched matrix multiply for multi-head attention.
 * A: [batch, M, K], B: [batch, K, N], C: [batch, M, N]
 */
int cublas_sgemm_batched(
    float* C, const float* A, const float* B,
    int batch_size, int M, int N, int K,
    float alpha, float beta
);

// ============================================================================
// Custom CUDA Kernels
// ============================================================================

/**
 * RMS Normalization (LLaMA style)
 * dst = src * rsqrt(mean(src^2) + eps) * weight
 */
int cuda_rms_norm(
    float* dst, const float* src, const float* weight,
    int n, float eps
);

/**
 * Batched RMS Normalization
 * Process multiple vectors in parallel.
 */
int cuda_rms_norm_batched(
    float* dst, const float* src, const float* weight,
    int batch_size, int n, float eps
);

/**
 * SiLU/Swish activation: x * sigmoid(x)
 */
int cuda_silu(float* dst, const float* src, int n);

/**
 * In-place SiLU
 */
int cuda_silu_inplace(float* data, int n);

/**
 * GELU activation
 */
int cuda_gelu(float* dst, const float* src, int n);

/**
 * ReLU activation
 */
int cuda_relu(float* dst, const float* src, int n);

/**
 * Softmax along last dimension
 */
int cuda_softmax(float* data, int n);

/**
 * Batched softmax (for attention scores)
 */
int cuda_softmax_batched(float* data, int batch_size, int n);

/**
 * Element-wise vector addition: dst = a + b
 */
int cuda_vec_add(float* dst, const float* a, const float* b, int n);

/**
 * Element-wise vector multiplication: dst = a * b
 */
int cuda_vec_mul(float* dst, const float* a, const float* b, int n);

/**
 * Scale vector: dst = src * scale
 */
int cuda_vec_scale(float* dst, const float* src, float scale, int n);

/**
 * Fused multiply-add: dst = a * b + c
 */
int cuda_vec_fma(float* dst, const float* a, const float* b, const float* c, int n);

/**
 * Dot product
 */
int cuda_dot(float* result, const float* a, const float* b, int n);

/**
 * Sum reduction
 */
int cuda_sum(float* result, const float* data, int n);

/**
 * Max reduction
 */
int cuda_max(float* result, const float* data, int n);

// ============================================================================
// Attention Kernels
// ============================================================================

/**
 * Rotary Position Embedding (RoPE)
 * Applies rotary embeddings to query and key vectors.
 */
int cuda_rope(
    float* q, float* k,
    int pos, int head_dim, float base_freq,
    int batch_size
);

/**
 * Fused attention: softmax(Q @ K^T / sqrt(d)) @ V
 * For flash attention style computation.
 */
int cuda_attention(
    float* output,           // [batch, seq, dim]
    const float* Q,          // [batch, seq, dim]
    const float* K,          // [batch, seq, dim]
    const float* V,          // [batch, seq, dim]
    int batch_size,
    int seq_len,
    int head_dim,
    int num_heads,
    float scale,
    int causal                // 1 for causal mask, 0 for no mask
);

// ============================================================================
// Quantization Kernels
// ============================================================================

/**
 * Dequantize Q8_0 blocks to F32
 * Q8_0: 32 values per block, 1 f16 scale + 32 int8 quantized
 */
int cuda_dequant_q8_0(
    float* dst,
    const void* src,  // BlockQ8_0 array
    int num_blocks
);

/**
 * Dequantize Q4_0 blocks to F32
 * Q4_0: 32 values per block, 1 f16 scale + 16 bytes (2 values per byte)
 */
int cuda_dequant_q4_0(
    float* dst,
    const void* src,  // BlockQ4_0 array
    int num_blocks
);

/**
 * Quantized matrix-vector multiply (Q8_0 weights)
 */
int cuda_matvec_q8_0(
    float* y,
    const void* A_q8,  // Quantized weight matrix
    const float* x,
    int M, int K
);

// ============================================================================
// SwiGLU Fused Kernel
// ============================================================================

/**
 * SwiGLU: silu(gate) * up
 * Fused kernel for efficiency.
 */
int cuda_swiglu(float* dst, const float* gate, const float* up, int n);

// ============================================================================
// Layer Normalization
// ============================================================================

/**
 * Layer normalization with bias
 */
int cuda_layer_norm(
    float* dst, const float* src,
    const float* weight, const float* bias,
    int n, float eps
);

// ============================================================================
// Synchronization
// ============================================================================

/**
 * Synchronize GPU operations.
 */
int cuda_synchronize(void);

/**
 * Get last CUDA error message.
 */
const char* cuda_get_last_error(void);

#ifdef __cplusplus
}
#endif

#endif // CUDA_KERNELS_H
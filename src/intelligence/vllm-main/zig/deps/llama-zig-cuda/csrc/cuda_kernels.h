/**
 * CUDA Kernels for Zig llama
 *
 * C header for Zig FFI bindings to CUDA/cuBLAS operations.
 * Provides GPU-accelerated kernels for LLM inference.
 *
 * ## Conventions
 * - All pointer parameters are **device pointers** unless documented otherwise.
 * - All functions return a CudaErrorCode (0 = success, negative = error).
 * - Functions are **not** thread-safe unless stated. All kernel launches go to
 *   the default stream (stream 0). Use the CUDA graph / stream APIs in
 *   cuda_graphs.cu for multi-stream work.
 * - Memory ownership: callers own all buffers. Functions never allocate output
 *   buffers on behalf of the caller (internal scratch is freed before return).
 * - Row-major layout is assumed for matrices unless noted.
 */

#ifndef CUDA_KERNELS_H
#define CUDA_KERNELS_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Error Codes
// ============================================================================

/**
 * Error codes returned by CUDA kernel functions.
 * All functions return 0 on success. Negative values indicate errors.
 * Use cuda_error_string() to get a human-readable description.
 */
typedef enum {
    CUDA_OK                  =  0,  /**< Success */
    CUDA_ERR_NOT_INITIALIZED = -1,  /**< CUDA not initialized; call cuda_init() first */
    CUDA_ERR_NO_DEVICE       = -2,  /**< No CUDA-capable device found */
    CUDA_ERR_ALLOC           = -3,  /**< Device memory allocation failed */
    CUDA_ERR_MEMCPY          = -4,  /**< Memory copy failed */
    CUDA_ERR_KERNEL          = -5,  /**< Kernel launch or execution failed */
    CUDA_ERR_CUBLAS          = -6,  /**< cuBLAS operation failed */
    CUDA_ERR_INVALID_ARG     = -7,  /**< Invalid argument (null pointer, bad dimension, etc.) */
    CUDA_ERR_OUT_OF_RANGE    = -8,  /**< Index or size out of valid range */
    CUDA_ERR_GRAPH           = -9,  /**< CUDA graph capture/launch/update failed */
    CUDA_ERR_NOT_SUPPORTED   = -10, /**< Operation not supported on this device */
} CudaErrorCode;

/**
 * Return a human-readable string for a CudaErrorCode.
 * Never returns NULL; returns "Unknown error" for unrecognised codes.
 */
const char* cuda_error_string(int error_code);

// ============================================================================
// Initialization & Device Management
// ============================================================================

/**
 * Initialize CUDA context, select device 0, and create the cuBLAS handle.
 * Must be called before any other cuda_* function.
 *
 * @return CUDA_OK on success, CUDA_ERR_NO_DEVICE if no GPU found.
 */
int cuda_init(void);

/**
 * Shutdown CUDA context, destroy cuBLAS handle, and release global state.
 * Safe to call multiple times; subsequent calls are no-ops.
 */
void cuda_shutdown(void);

/**
 * Check if CUDA is available and initialized.
 *
 * @return 1 if cuda_init() succeeded and a device is ready, 0 otherwise.
 */
int cuda_is_available(void);

/**
 * Query device properties for the active GPU.
 *
 * @param info  Host pointer to a CudaDeviceInfo struct (caller-owned).
 * @return CUDA_OK on success, CUDA_ERR_NOT_INITIALIZED if no device.
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
 *
 * @param size  Number of bytes to allocate.
 * @return Device pointer, or NULL on failure. Caller must free with cuda_free().
 */
void* cuda_malloc(size_t size);

/**
 * Free GPU memory previously allocated with cuda_malloc().
 * No-op if ptr is NULL.
 *
 * @param ptr  Device pointer (or NULL).
 */
void cuda_free(void* ptr);

/**
 * Copy data from host to device.
 *
 * @param dst   Device destination pointer.
 * @param src   Host source pointer.
 * @param size  Bytes to copy.
 * @return CUDA_OK or CUDA_ERR_MEMCPY.
 */
int cuda_memcpy_h2d(void* dst, const void* src, size_t size);

/**
 * Copy data from device to host.
 *
 * @param dst   Host destination pointer.
 * @param src   Device source pointer.
 * @param size  Bytes to copy.
 * @return CUDA_OK or CUDA_ERR_MEMCPY.
 */
int cuda_memcpy_d2h(void* dst, const void* src, size_t size);

/**
 * Copy data device to device.
 *
 * @param dst   Device destination pointer.
 * @param src   Device source pointer.
 * @param size  Bytes to copy.
 * @return CUDA_OK or CUDA_ERR_MEMCPY.
 */
int cuda_memcpy_d2d(void* dst, const void* src, size_t size);

/**
 * Set device memory to a byte value.
 *
 * @param ptr    Device pointer.
 * @param value  Byte value to set (only low 8 bits used).
 * @param size   Number of bytes.
 * @return CUDA_OK or CUDA_ERR_MEMCPY.
 */
int cuda_memset(void* ptr, int value, size_t size);

// ============================================================================
// cuBLAS Matrix Operations
// ============================================================================

/**
 * Initialize cuBLAS handle. Called automatically by cuda_init();
 * safe to call again (no-op if already initialized).
 *
 * @return CUDA_OK or CUDA_ERR_CUBLAS.
 */
int cublas_init(void);

/**
 * Destroy the cuBLAS handle. Called automatically by cuda_shutdown().
 */
void cublas_shutdown(void);

/**
 * Single-precision general matrix multiply (SGEMM).
 *   C = alpha * A @ B + beta * C
 *
 * All matrices are row-major; the implementation transposes for cuBLAS.
 *
 * @param C      Device pointer [M, N], read if beta != 0, always written.
 * @param A      Device pointer [M, K], read-only.
 * @param B      Device pointer [K, N], read-only.
 * @param M      Number of rows in A / C.
 * @param N      Number of columns in B / C.
 * @param K      Shared inner dimension.
 * @param alpha  Scalar multiplier for A @ B.
 * @param beta   Scalar multiplier for existing C (use 0.0f to overwrite).
 * @return CUDA_OK or CUDA_ERR_CUBLAS.
 */
int cublas_sgemm(
    float* C, const float* A, const float* B,
    int M, int N, int K,
    float alpha, float beta
);

/**
 * Single-precision matrix-vector multiply (SGEMV).
 *   y = alpha * A @ x + beta * y
 *
 * @param y      Device pointer [M], read if beta != 0, always written.
 * @param A      Device pointer [M, K], read-only.
 * @param x      Device pointer [K], read-only.
 * @param M      Number of rows in A (length of y).
 * @param K      Number of columns in A (length of x).
 * @param alpha  Scalar multiplier.
 * @param beta   Scalar multiplier for existing y.
 * @return CUDA_OK or CUDA_ERR_CUBLAS.
 */
int cublas_sgemv(
    float* y, const float* A, const float* x,
    int M, int K,
    float alpha, float beta
);

/**
 * SGEMM with B transposed (row-major).
 *   C = alpha * A @ B^T + beta * C
 *
 * @param C      Device pointer [M, N].
 * @param A      Device pointer [M, K], read-only.
 * @param B      Device pointer [N, K], read-only (transposed to [K, N] internally).
 * @param M      Rows of A / C.
 * @param N      Rows of B (= columns of B^T = columns of C).
 * @param K      Shared inner dimension.
 * @param alpha  Scalar multiplier for A @ B^T.
 * @param beta   Scalar multiplier for existing C.
 * @return CUDA_OK or CUDA_ERR_CUBLAS.
 */
int cublas_sgemm_transB(
    float* C, const float* A, const float* B,
    int M, int N, int K,
    float alpha, float beta
);

/**
 * Batched SGEMM for multi-head attention.
 * Processes `batch_size` independent GEMMs with strided pointers.
 *
 * @param C           Device pointer [batch, M, N].
 * @param A           Device pointer [batch, M, K].
 * @param B           Device pointer [batch, K, N].
 * @param batch_size  Number of independent multiplications.
 * @param M, N, K     Matrix dimensions per batch element.
 * @param alpha, beta Scalar multipliers.
 * @return CUDA_OK or CUDA_ERR_CUBLAS.
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
 * RMS Normalization (LLaMA style).
 *   dst[i] = src[i] * rsqrt(mean(src²) + eps) * weight[i]
 *
 * Processes a single vector of length n. Uses shared memory reduction.
 *
 * @param dst     Device output [n].
 * @param src     Device input  [n] (may alias dst for in-place).
 * @param weight  Device per-element scale [n].
 * @param n       Vector length (must be > 0).
 * @param eps     Small constant for numerical stability (e.g. 1e-5f).
 * @return CUDA_OK, CUDA_ERR_INVALID_ARG, or CUDA_ERR_KERNEL.
 */
int cuda_rms_norm(
    float* dst, const float* src, const float* weight,
    int n, float eps
);

/**
 * Batched RMS Normalization.
 * Applies cuda_rms_norm independently to each of `batch_size` contiguous
 * vectors of length n in src/dst. Weight is shared across all rows.
 *
 * @param dst         Device output [batch_size, n].
 * @param src         Device input  [batch_size, n].
 * @param weight      Device scale  [n] (broadcast over batch).
 * @param batch_size  Number of rows.
 * @param n           Elements per row.
 * @param eps         Stability constant.
 * @return CUDA_OK or error code.
 */
int cuda_rms_norm_batched(
    float* dst, const float* src, const float* weight,
    int batch_size, int n, float eps
);

/**
 * SiLU/Swish activation: dst[i] = src[i] * sigmoid(src[i]).
 *
 * @param dst  Device output [n].
 * @param src  Device input  [n] (may alias dst).
 * @param n    Number of elements.
 * @return CUDA_OK or CUDA_ERR_INVALID_ARG.
 */
int cuda_silu(float* dst, const float* src, int n);

/**
 * In-place SiLU. Equivalent to cuda_silu(data, data, n).
 */
int cuda_silu_inplace(float* data, int n);

/**
 * GELU activation (tanh approximation).
 *   dst[i] = x * 0.5 * (1 + tanh(sqrt(2/π) * (x + 0.044715 * x³)))
 *
 * @param dst  Device output [n].
 * @param src  Device input  [n] (may alias dst).
 * @param n    Number of elements.
 * @return CUDA_OK or CUDA_ERR_INVALID_ARG.
 */
int cuda_gelu(float* dst, const float* src, int n);

/**
 * ReLU activation: dst[i] = max(src[i], 0).
 *
 * @param dst  Device output [n].
 * @param src  Device input  [n] (may alias dst).
 * @param n    Number of elements.
 * @return CUDA_OK or CUDA_ERR_INVALID_ARG.
 */
int cuda_relu(float* dst, const float* src, int n);

/**
 * In-place softmax over a single vector.
 * Numerically stable: subtracts max before exp.
 *
 * @param data  Device pointer [n], modified in-place.
 * @param n     Vector length.
 * @return CUDA_OK or CUDA_ERR_INVALID_ARG.
 */
int cuda_softmax(float* data, int n);

/**
 * Batched softmax. Applies cuda_softmax to each of `batch_size` contiguous
 * vectors of length n.
 *
 * @param data        Device pointer [batch_size, n], modified in-place.
 * @param batch_size  Number of independent softmax rows.
 * @param n           Elements per row.
 * @return CUDA_OK or error code.
 */
int cuda_softmax_batched(float* data, int batch_size, int n);

/**
 * Element-wise vector addition: dst[i] = a[i] + b[i].
 * dst may alias a or b for in-place operation.
 *
 * @param dst  Device output [n].
 * @param a    Device input  [n].
 * @param b    Device input  [n].
 * @param n    Number of elements.
 * @return CUDA_OK or CUDA_ERR_INVALID_ARG.
 */
int cuda_vec_add(float* dst, const float* a, const float* b, int n);

/**
 * Element-wise vector multiplication: dst[i] = a[i] * b[i].
 *
 * @param dst  Device output [n].
 * @param a    Device input  [n].
 * @param b    Device input  [n].
 * @param n    Number of elements.
 * @return CUDA_OK or CUDA_ERR_INVALID_ARG.
 */
int cuda_vec_mul(float* dst, const float* a, const float* b, int n);

/**
 * Scale vector: dst[i] = src[i] * scale.
 *
 * @param dst    Device output [n].
 * @param src    Device input  [n] (may alias dst).
 * @param scale  Scalar multiplier.
 * @param n      Number of elements.
 * @return CUDA_OK or CUDA_ERR_INVALID_ARG.
 */
int cuda_vec_scale(float* dst, const float* src, float scale, int n);

/**
 * Fused multiply-add: dst[i] = a[i] * b[i] + c[i].
 * Uses hardware FMA (fmaf) for better precision.
 *
 * @param dst  Device output [n].
 * @param a    Device input  [n].
 * @param b    Device input  [n].
 * @param c    Device input  [n].
 * @param n    Number of elements.
 * @return CUDA_OK or CUDA_ERR_INVALID_ARG.
 */
int cuda_vec_fma(float* dst, const float* a, const float* b, const float* c, int n);

/**
 * Dot product via cuBLAS: result = Σ a[i] * b[i].
 *
 * @param result  Device pointer to a single float (output).
 * @param a       Device input [n].
 * @param b       Device input [n].
 * @param n       Number of elements.
 * @return CUDA_OK or CUDA_ERR_CUBLAS.
 */
int cuda_dot(float* result, const float* a, const float* b, int n);

/**
 * Sum reduction: result = Σ data[i].
 * Uses shared memory block reduction.
 *
 * @param result  Device pointer to a single float (output).
 * @param data    Device input [n].
 * @param n       Number of elements.
 * @return CUDA_OK or CUDA_ERR_KERNEL.
 */
int cuda_sum(float* result, const float* data, int n);

/**
 * Max reduction: result = max(data[0..n-1]).
 *
 * @param result  Device pointer to a single float (output).
 * @param data    Device input [n].
 * @param n       Number of elements.
 * @return CUDA_OK or CUDA_ERR_KERNEL.
 */
int cuda_max(float* result, const float* data, int n);

// ============================================================================
// Attention Kernels
// ============================================================================

/**
 * Rotary Position Embedding (RoPE).
 * Applies sinusoidal rotation to interleaved (q0,q1) pairs in-place.
 * head_dim must be even.
 *
 * @param q          Device pointer to query vectors [batch_size, head_dim], modified in-place.
 * @param k          Device pointer to key vectors   [batch_size, head_dim], modified in-place.
 * @param pos        Token position index for frequency computation.
 * @param head_dim   Per-head dimension (must be > 0 and even).
 * @param base_freq  RoPE base frequency (e.g. 10000.0f).
 * @param batch_size Number of (query, key) pairs = num_sequences * num_heads.
 * @return CUDA_OK or CUDA_ERR_INVALID_ARG.
 */
int cuda_rope(
    float* q, float* k,
    int pos, int head_dim, float base_freq,
    int batch_size
);

/**
 * Simplified multi-head attention (non-flash).
 *   output = softmax(Q @ K^T * scale) @ V
 *
 * Materialises the full [seq, seq] score matrix — O(N²) memory.
 * For long sequences (>512), use flash_attention_forward() instead.
 *
 * @param output      Device output [batch_size * num_heads, seq_len, head_dim].
 * @param Q           Device query  [batch_size * num_heads, seq_len, head_dim].
 * @param K           Device key    [batch_size * num_heads, seq_len, head_dim].
 * @param V           Device value  [batch_size * num_heads, seq_len, head_dim].
 * @param batch_size  Number of sequences.
 * @param seq_len     Sequence length (Q and K must match).
 * @param head_dim    Per-head dimension.
 * @param num_heads   Number of attention heads.
 * @param scale       Score scaling factor, typically 1/sqrt(head_dim).
 * @param causal      1 for causal (autoregressive) mask, 0 for bidirectional.
 * @return CUDA_OK or CUDA_ERR_INVALID_ARG / CUDA_ERR_ALLOC.
 */
int cuda_attention(
    float* output,
    const float* Q,
    const float* K,
    const float* V,
    int batch_size,
    int seq_len,
    int head_dim,
    int num_heads,
    float scale,
    int causal
);

// ============================================================================
// Quantization Kernels
// ============================================================================

/**
 * Dequantize Q8_0 blocks to FP32.
 * Q8_0 format: 32 values per block — 1 FP16 scale + 32 INT8 weights.
 * Output length = num_blocks * 32.
 *
 * @param dst         Device FP32 output [num_blocks * 32].
 * @param src         Device Q8_0 block array.
 * @param num_blocks  Number of Q8_0 blocks.
 * @return CUDA_OK or CUDA_ERR_KERNEL.
 */
int cuda_dequant_q8_0(
    float* dst,
    const void* src,
    int num_blocks
);

/**
 * Dequantize Q4_0 blocks to FP32.
 * Q4_0 format: 32 values per block — 1 FP16 scale + 16 bytes (4-bit nibbles).
 * Values are centered: nibble - 8.
 * Output length = num_blocks * 32.
 *
 * @param dst         Device FP32 output [num_blocks * 32].
 * @param src         Device Q4_0 block array.
 * @param num_blocks  Number of Q4_0 blocks.
 * @return CUDA_OK or CUDA_ERR_KERNEL.
 */
int cuda_dequant_q4_0(
    float* dst,
    const void* src,
    int num_blocks
);

/**
 * Quantized matrix-vector multiply with Q8_0 weights.
 * Dequantizes A to a temporary FP32 buffer, then uses cuBLAS SGEMV.
 *
 * @param y     Device FP32 output [M].
 * @param A_q8  Device Q8_0 weight matrix [M * K / 32 blocks].
 * @param x     Device FP32 input [K].
 * @param M     Output dimension (rows of A).
 * @param K     Input dimension (columns of A).
 * @return CUDA_OK, CUDA_ERR_ALLOC, or CUDA_ERR_CUBLAS.
 * @note Allocates M*K*sizeof(float) temporary memory internally.
 */
int cuda_matvec_q8_0(
    float* y,
    const void* A_q8,
    const float* x,
    int M, int K
);

// ============================================================================
// SwiGLU Fused Kernel
// ============================================================================

/**
 * SwiGLU activation: dst[i] = silu(gate[i]) * up[i].
 * Fused into a single kernel to halve global memory traffic.
 *
 * @param dst   Device output [n].
 * @param gate  Device gate input [n].
 * @param up    Device up-projection input [n].
 * @param n     Number of elements.
 * @return CUDA_OK or CUDA_ERR_INVALID_ARG.
 */
int cuda_swiglu(float* dst, const float* gate, const float* up, int n);

// ============================================================================
// Layer Normalization
// ============================================================================

/**
 * Layer normalization with learned weight and bias.
 *   dst[i] = (src[i] - mean) / sqrt(var + eps) * weight[i] + bias[i]
 *
 * @param dst     Device output [n].
 * @param src     Device input  [n].
 * @param weight  Device per-element scale [n].
 * @param bias    Device per-element bias  [n] (may be NULL for no bias).
 * @param n       Vector length.
 * @param eps     Stability constant.
 * @return CUDA_OK or error code.
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
 * Block until all preceding GPU operations on the default stream complete.
 *
 * @return CUDA_OK or CUDA_ERR_KERNEL.
 */
int cuda_synchronize(void);

/**
 * Get last CUDA error as a human-readable string from the CUDA runtime.
 * The returned pointer is to a static buffer; valid until the next error.
 *
 * @return Null-terminated error string (never NULL).
 */
const char* cuda_get_last_error(void);

/**
 * Get last CUDA error as a CudaErrorCode.
 *
 * @return Most recent CudaErrorCode set by any cuda_* function.
 */
int cuda_get_last_error_code(void);

// ============================================================================
// GPU Capability Detection
// ============================================================================

/** @return 1 if Tensor Cores are available (SM >= 7.0), 0 otherwise. */
int cuda_has_tensor_cores(void);

/** @return 1 if native FP16 arithmetic is supported (SM >= 5.3), 0 otherwise. */
int cuda_has_fp16(void);

/** @return 1 if INT8 Tensor Core GEMM is supported (SM >= 7.5), 0 otherwise. */
int cuda_has_int8_tensor(void);

/**
 * Query full GPU capability flags.
 * Any output pointer may be NULL to skip that field.
 */
int cuda_get_capabilities(
    int* sm_version, int* has_tc, int* has_fp16,
    int* has_int8_tc, int* has_bf16
);

// ============================================================================
// INT8 Quantization (int8_quantization.cu)
// ============================================================================

int int8_quantization_init(void);
void int8_quantization_shutdown(void);

int calibrate_layer(
    float* min_val, float* max_val,
    const float* activations, int n
);

int quantize_fp32_to_int8(
    int8_t* output, const float* input,
    float scale, int zero_point, int n
);

int quantize_per_channel(
    int8_t* output, const float* input,
    const float* scales, int num_channels, int channel_size
);

int apply_smooth_quant(
    float* x_smoothed, float* w_smoothed,
    const float* x, const float* w,
    const float* smooth_scales,
    int batch_size, int hidden_dim
);

int int8_gemm(
    int32_t* C, const int8_t* A, const int8_t* B,
    int M, int N, int K,
    int32_t alpha, int32_t beta
);

int dynamic_quantize(
    int8_t* output, float* scale_out,
    const float* input, int batch_size, int hidden_dim
);

int awq_dequantize(
    float* output, const int8_t* weights,
    const float* scales, const int8_t* zeros,
    int group_size, int num_groups
);

/** GPTQ quantization — CPU fallback path. */
int gptq_quantize_block(
    int8_t* q_weights, float* scales,
    const float* weights, const float* H_inv,
    int rows, int cols, int group_size
);

/** GPTQ quantization — GPU-accelerated path (all on device). */
int gptq_quantize_block_gpu(
    int8_t* q_weights, float* scales,
    float* weights, const float* H_inv,
    int rows, int cols, int group_size
);

/**
 * Fused W4A16 GEMM: C = A × dequant(B_packed)^T
 * Reads packed INT4 weights, dequantizes per-group, accumulates in FP32.
 *
 * @param C          Device FP32 output [M, N].
 * @param A          Device FP32 activations [M, K].
 * @param B_packed   Device packed INT4 weights [N, K/2].
 * @param scales     Device FP32 per-group scales [N, K/group_size].
 * @param M          Batch dimension.
 * @param N          Output dimension.
 * @param K          Inner dimension (must be even).
 * @param group_size Quantization group size (e.g. 128).
 */
int w4a16_gemm(
    float* C, const float* A,
    const uint8_t* B_packed, const float* scales,
    int M, int N, int K, int group_size
);

// ============================================================================
// Flash Attention (flash_attention.cu)
// ============================================================================

int flash_attention_forward(
    float* output, const float* query, const float* key, const float* value,
    int batch_size, int num_heads, int seq_len, int head_dim,
    float scale, int causal
);

int flash_attention_forward_fp16(
    void* output, const void* query, const void* key, const void* value,
    int batch_size, int num_heads, int seq_len, int head_dim,
    float scale, int causal
);

int flash_gqa_forward(
    float* output, const float* query, const float* key, const float* value,
    int batch_size, int num_q_heads, int num_kv_heads, int seq_len, int head_dim,
    float scale, int causal
);

/** Query the runtime-selected tile configuration (after auto-tune). */
int flash_attention_get_tile_config(
    int* tile_q_fp32, int* tile_k_fp32,
    int* tile_q_fp16, int* tile_k_fp16,
    int* sm_version
);

// ============================================================================
// CUDA Streams & Events (cuda_graphs.cu)
// ============================================================================

int cuda_stream_pool_init(void);
void cuda_stream_pool_destroy(void);
void* cuda_get_stream(int idx);
int cuda_stream_synchronize(void* stream);
int cuda_stream_wait_event(void* stream, void* event);

void* cuda_event_create(void);
void  cuda_event_destroy(void* event);
int   cuda_event_record(void* event, void* stream);
int   cuda_event_synchronize(void* event);
int   cuda_event_elapsed_time(float* ms, void* start, void* end);

// ============================================================================
// CUDA Graphs (cuda_graphs.cu)
// ============================================================================

int cuda_graph_begin_capture(int graph_id);
int cuda_graph_end_capture(int graph_id);
int cuda_graph_launch(int graph_id);
int cuda_graph_sync(int graph_id);
int cuda_graph_destroy(int graph_id);
int cuda_graph_try_update(int graph_id, int new_batch_size, int new_seq_len);

/** Pre-capture decode graphs for all batch size buckets. */
int cuda_graph_precapture_decode(
    float* output, const float* input, const float* weights,
    int hidden_dim, int num_layers
);

/** Pre-capture prefill graphs for all (batch, seq_len) bucket combinations. */
int cuda_graph_precapture_prefill(
    float* output, const float* input, const float* weights,
    int hidden_dim, int num_layers
);

/** Launch the best matching decode graph for the given batch size. */
int cuda_graph_launch_decode_bucketed(int batch_size);

/** Launch the best matching prefill graph for the given (batch, seq_len). */
int cuda_graph_launch_prefill_bucketed(int batch_size, int seq_len);

int cuda_graph_update_node(int graph_id, int node_idx, void** new_args, int num_args);
int cuda_graph_profile(int graph_id, float* ms_elapsed);

int cuda_graph_memory_init(size_t scratch_size, size_t kv_cache_size);
void cuda_graph_memory_destroy(void);
void* cuda_graph_get_scratch(void);
void* cuda_graph_get_kv_cache(void);

int cuda_graph_create_decode_step(
    int graph_id,
    float* output, const float* input, const float* weights,
    int batch_size, int hidden_dim, int num_layers
);

int cuda_pipeline_layer(
    int layer_idx,
    float* output, const float* input, const float* weights,
    float* staging_buffer, const float* next_weights,
    size_t weights_size, int batch_size, int hidden_dim
);

// ============================================================================
// Speculative Decoding (cuda_graphs.cu)
// ============================================================================

int cuda_speculative_init(int num_speculative_tokens, int hidden_dim, int vocab_size);
void cuda_speculative_shutdown(void);

int cuda_speculative_draft(
    int* draft_tokens, float* draft_probs,
    const float* input, const float* draft_weights,
    int num_layers, int vocab_size
);

int cuda_speculative_verify(
    int* accepted_tokens, int* num_accepted,
    const int* draft_tokens, const float* draft_probs,
    const float* input, const float* main_weights,
    int num_layers, int vocab_size, int num_speculative
);

// ============================================================================
// Continuous Batching & PagedAttention (continuous_batching.cu)
// ============================================================================

int paged_kv_cache_init(int max_pages, int num_layers, int num_kv_heads, int head_dim);
void paged_kv_cache_shutdown(void);
int allocate_page(int sequence_id);
void free_sequence_pages(int sequence_id);
int beam_search_fork(int parent_seq_id);

int continuous_batch_init(void);
void continuous_batch_shutdown(void);
int continuous_batch_step(
    void* output_logits,          /* [num_sequences, vocab_size] FP16 */
    const void* model_weights,    /* contiguous FP16 model weights    */
    int vocab_size
);

int prefix_cache_lookup(
    const int32_t* tokens, int length,
    int32_t* cached_page_ids, int max_pages
);
int prefix_cache_insert(
    const int32_t* tokens, int length,
    int page_id
);

/** Set radix tree backend for prefix caching (replaces hash table). */
typedef int (*radix_lookup_fn)(const int32_t* tokens, int length,
                               int32_t* cached_page_ids, int max_pages);
typedef int (*radix_insert_fn)(const int32_t* tokens, int length, int page_id);
void prefix_cache_set_radix_backend(radix_lookup_fn lookup_fn, radix_insert_fn insert_fn);

/** Configure model capabilities (MLA, INT8 KV, Flash V2). Call before first step. */
void continuous_batch_set_model_config(
    bool use_mla, bool use_int8_kv, bool use_flash_v2,
    int mla_latent_dim, int mla_rope_dim, int mla_nope_dim
);

/** Set MLA weight and cache device pointers. Call after set_model_config. */
void continuous_batch_set_mla_weights(
    float* w_kv_down, float* w_kv_up, float* w_k_rope,
    float* w_k_up, float* w_v_up,
    float* latent_cache, float* k_rope_cache
);

typedef struct {
    int total_pages;
    int used_pages;
    int free_pages;
    int active_sequences;
    size_t total_memory_bytes;
    size_t used_memory_bytes;
    float utilization;
} MemoryStats;

void get_memory_stats(MemoryStats* stats);

// CPU fallback scheduler
int cpu_scheduler_init(void);
int cpu_scheduler_enqueue(int seq_id);
int cpu_scheduler_build_batch(int* batch_seq_ids, int* batch_size, int max_batch_size);
void cpu_scheduler_finish(int seq_id);
int cpu_scheduler_preempt_longest(void);
void cpu_scheduler_shutdown(void);

// CUDA graph integration for decode step
void batch_decode_graph_invalidate(void);
int batch_decode_step_graphed(
    void* output, const void* query,
    int batch_size, int max_seq_len, float scale
);
int batch_decode_graph_sync(void);
void batch_decode_graph_shutdown(void);

// ============================================================================
// Tensor Parallelism (NCCL)
// ============================================================================

/**
 * Initialize tensor parallelism with NCCL.
 *
 * @param nccl_unique_id_bytes  Opaque NCCL unique ID (tp_unique_id_size() bytes).
 * @param rank       This GPU's rank [0, tp_size).
 * @param tp_size    Total number of GPUs in the TP group.
 * @param hidden_dim Model hidden dimension (must be divisible by tp_size).
 * @param num_heads  Total attention heads (must be divisible by tp_size).
 * @param head_dim   Dimension per attention head.
 * @param vocab_size Vocabulary size.
 * @return 0 on success.
 */
int tp_init(
    const char* nccl_unique_id_bytes,
    int rank, int tp_size,
    int hidden_dim, int num_heads, int head_dim, int vocab_size
);

/** Generate NCCL unique ID (rank 0 only, then broadcast to other ranks). */
int tp_get_unique_id(char* out);

/** Size in bytes of the NCCL unique ID buffer. */
int tp_unique_id_size(void);

/** Shut down tensor parallelism and free all resources. */
void tp_shutdown(void);

/** In-place sum all-reduce on `count` floats (async on NCCL stream). */
int tp_allreduce(float* buf, int count);

/** All-reduce + synchronise (blocks until complete). */
int tp_allreduce_sync(float* buf, int count);

/** All-gather: each rank sends `send_count`, recv_buf gets tp_size * send_count. */
int tp_allgather(float* recv_buf, const float* send_buf, int send_count);

/** Make compute stream wait for NCCL stream completion. */
int tp_sync_comm_to_compute(void);

/** Make NCCL stream wait for compute stream completion. */
int tp_sync_compute_to_comm(void);

/**
 * Shard a weight matrix for row-parallel linear (output-dim sharding).
 * Full [in_dim, out_dim] → shard [in_dim, out_dim/tp_size].
 */
int tp_shard_weight_row_parallel(
    float* d_shard, const float* h_full, int in_dim, int out_dim
);

/**
 * Shard a weight matrix for column-parallel linear (input-dim sharding).
 * Full [in_dim, out_dim] → shard [in_dim/tp_size, out_dim].
 */
int tp_shard_weight_col_parallel(
    float* d_shard, const float* h_full, int in_dim, int out_dim
);

/** Shard a 1-D vector into tp_size equal parts. */
int tp_shard_vector(float* d_shard, const float* h_full, int dim);

/** Row-parallel linear: y_shard = x @ W_shard. Needs all-reduce after. */
int tp_row_parallel_linear(
    float* y_shard, const float* x, const float* w_shard,
    int M, int in_dim, int shard_out
);

/** Column-parallel linear: y = x_shard @ W_shard. No communication needed. */
int tp_col_parallel_linear(
    float* y, const float* x_shard, const float* w_shard,
    int M, int shard_in, int out_dim
);

/** Per-layer weight stride for sharded weights (floats). */
size_t tp_layer_weight_stride(void);

/**
 * Run one transformer layer with tensor parallelism (single-token decode).
 * hidden [hidden_dim] is updated in-place (replicated on all ranks).
 * 2 all-reduces per layer (attention + FFN).
 */
int tp_transformer_layer(
    float* hidden, const float* layer_weights, int position
);

/**
 * Full TP forward pass for single-token decode.
 * Runs all layers, final norm, and LM head with logits gathering.
 *
 * @param output_logits  Device [vocab_size], valid on all ranks.
 * @param input_hidden   Device [hidden_dim], replicated on all ranks.
 * @param weights        Device sharded weights for this rank.
 * @param num_layers     Number of transformer layers.
 * @param position       Sequence position for RoPE.
 */
int tp_forward_decode(
    float* output_logits, const float* input_hidden,
    const float* weights, int num_layers, int position
);

/** Query TP state. */
int tp_get_rank(void);
int tp_get_size(void);
int tp_get_shard_dim(void);
int tp_get_shard_heads(void);
int tp_is_initialized(void);

// ============================================================================
// ChatGLM5 Model-Specific Kernels (glm5_kernels.cu)
// ============================================================================

int glm5_rope_forward(
    float* query, float* key,
    int batch_size, int seq_len, int num_q_heads, int num_kv_heads, int head_dim,
    int rope_dim, float theta_base
);

int glm5_mqa_forward(
    float* output, const float* query, const float* key, const float* value,
    int batch_size, int seq_len, int num_q_heads, int num_kv_heads, int head_dim,
    float scale, int causal
);

int glm5_swiglu_forward(
    float* output, const float* gate, const float* up,
    int batch_size, int seq_len, int hidden_dim
);

int glm5_rmsnorm_forward(
    float* output, const float* input, const float* weight,
    int batch_size, int seq_len, int hidden_dim, float eps
);

// ============================================================================
// Kimi2.5 Model-Specific Kernels (kimi25_kernels.cu)
// ============================================================================

int kimi25_yarn_rope_forward(
    float* query, float* key,
    int batch_size, int seq_len, int num_q_heads, int num_kv_heads, int head_dim,
    float theta_base, float scale_factor, float yarn_attn_factor
);

int kimi25_swa_forward(
    float* output, const float* query, const float* key, const float* value,
    int batch_size, int seq_len, int num_q_heads, int num_kv_heads, int head_dim,
    int window_size, float scale, int causal
);

int kimi25_silu_mul_forward(
    float* output, const float* gate, const float* up,
    int batch_size, int seq_len, int hidden_dim
);

// ============================================================================
// MiniMax2.5 Model-Specific Kernels (minimax25_kernels.cu)
// ============================================================================

/**
 * Lightning Attention Forward Pass
 *
 * Linear attention with gating: O(N*d²) instead of O(N²*d)
 * Computes: o_t = (q_t * gate_q) @ S_t where S_t = decay * S_{t-1} + k_t * v_t^T
 *
 * @param output       Device [batch, num_heads, seq_len, head_dim]
 * @param query        Device [batch, num_heads, seq_len, head_dim]
 * @param key          Device [batch, num_heads, seq_len, head_dim]
 * @param value        Device [batch, num_heads, seq_len, head_dim]
 * @param gate_q       Device [batch, num_heads, seq_len, head_dim] gating for query
 * @param gate_k       Device [batch, num_heads, seq_len, head_dim] gating for key
 * @param decay        Device [num_heads] per-head decay parameter
 * @param batch_size   Batch size
 * @param seq_len      Sequence length
 * @param num_heads    Number of attention heads
 * @param head_dim     Head dimension (typically 128)
 * @return CUDA_OK on success, CUDA_ERR_KERNEL on failure
 */
int minimax25_lightning_attention_forward(
    float* output, const float* query, const float* key, const float* value,
    const float* gate_q, const float* gate_k, const float* decay,
    int batch_size, int seq_len, int num_heads, int head_dim
);

/**
 * MoE Expert Routing
 *
 * Compute router logits and select top-k experts per token.
 * Applies softmax over experts and selects top-k highest probability experts.
 *
 * @param expert_indices   Device [batch*seq_len, top_k] expert indices per token
 * @param expert_weights   Device [batch*seq_len, top_k] expert weights (softmax probs)
 * @param hidden_states    Device [batch*seq_len, hidden_dim] token representations
 * @param gate_weight      Device [num_experts, hidden_dim] router weight matrix
 * @param batch_size       Batch size
 * @param seq_len          Sequence length
 * @param hidden_dim       Hidden dimension
 * @param num_experts      Number of experts (typically 8)
 * @param top_k            Number of experts to select per token (typically 2)
 * @return CUDA_OK on success, CUDA_ERR_KERNEL on failure
 */
int minimax25_moe_route(
    int* expert_indices, float* expert_weights,
    const float* hidden_states, const float* gate_weight,
    int batch_size, int seq_len, int hidden_dim,
    int num_experts, int top_k
);

/**
 * Fused SwiGLU for MoE FFN
 *
 * Computes: output = down_proj(swiglu(gate_proj(x), up_proj(x)))
 * Fuses gate*silu(up) step for efficiency.
 *
 * @param output              Device [num_tokens, hidden_dim] expert output
 * @param input               Device [num_tokens, hidden_dim] token input
 * @param gate_proj_weight    Device [intermediate_dim, hidden_dim] gate projection
 * @param up_proj_weight      Device [intermediate_dim, hidden_dim] up projection
 * @param down_proj_weight    Device [hidden_dim, intermediate_dim] down projection
 * @param num_tokens          Number of tokens assigned to this expert
 * @param hidden_dim          Hidden dimension
 * @param intermediate_dim    Intermediate FFN dimension (typically 4*hidden_dim)
 * @return CUDA_OK on success, CUDA_ERR_KERNEL on failure
 */
int minimax25_swiglu_expert_forward(
    float* output, const float* input,
    const float* gate_proj_weight, const float* up_proj_weight,
    const float* down_proj_weight,
    int num_tokens, int hidden_dim, int intermediate_dim
);

// ============================================================================
// Multi-Latent Attention (mla_kernels.cu)
// ============================================================================

/** Fused KV compression + RoPE: hidden → latent + k_rope. */
int mla_compress_kv(
    float* latent_out, float* k_rope_out,
    const float* x, const float* w_kv_down, const float* w_k_rope,
    int num_seq, int hidden_dim, int latent_dim,
    int num_kv_heads, int rope_dim, int position, float rope_theta
);

/** MLA attention with on-the-fly KV decompression from latent cache. */
int mla_attention_forward(
    float* output,
    const float* q_nope, const float* q_rope,
    const float* latent_cache, const float* k_rope_cache,
    const float* w_k_up, const float* w_v_up,
    int num_seq, int seq_len,
    int num_heads, int num_kv_heads, int head_dim,
    int nope_dim, int rope_dim, int latent_dim, float scale
);

// ============================================================================
// Flash Attention V2 (flash_attention_v2.cu)
// ============================================================================

/** Fused Flash Attention reading directly from paged KV cache. O(N) memory. */
int flash_paged_attention_forward(
    void* output, const void* query,
    const void* k_pages, const void* v_pages,
    const int32_t* page_table, const int32_t* seq_lens,
    int num_seq, int num_heads, int num_kv_heads, int head_dim,
    int page_size, int max_blocks_per_seq, float scale
);

/** Warp-level batch decode kernel for seq_len=1 (single-token generation). */
int batch_decode_attention_forward(
    void* output, const void* query,
    const void* k_pages, const void* v_pages,
    const int32_t* page_table, const int32_t* seq_lens,
    int num_seq, int num_heads, int num_kv_heads, int head_dim,
    int page_size, int max_blocks_per_seq, float scale
);

/** Hopper-aware dispatcher: TMA kernel on SM 9.0+, standard otherwise. */
int flash_paged_attention_hopper(
    void* output, const void* query,
    const void* k_pages, const void* v_pages,
    const int32_t* page_table, const int32_t* seq_lens,
    int num_seq, int num_heads, int num_kv_heads, int head_dim,
    int page_size, int max_blocks_per_seq, float scale
);

/** Two-level cascade attention for long sequences with shared prefixes. */
int cascade_attention_forward(
    void* output, const void* query,
    const void* k_pages, const void* v_pages,
    const int32_t* page_table, const int32_t* seq_lens,
    const float* prefix_out, const float* prefix_lse,
    int prefix_len,
    int num_seq, int num_heads, int num_kv_heads, int head_dim,
    int page_size, int max_blocks_per_seq, float scale
);

// ============================================================================
// INT8 KV Cache (int8_kv_cache.cu)
// ============================================================================

int int8_kv_cache_init(int max_pages, int num_layers, int num_kv_heads, int head_dim);
void int8_kv_cache_shutdown(void);

int int8_kv_cache_store(
    const float* fp_k, const float* fp_v,
    const int32_t* page_ids, const int32_t* positions,
    int num_seq
);

int paged_attention_int8(
    void* output, const void* query,
    const int32_t* page_indices, const int32_t* seq_lengths,
    int num_seq, int num_heads, int num_kv_heads, int head_dim,
    int max_seq_len, int max_blocks_per_seq, float attn_scale
);

void int8_kv_cache_stats(
    int* out_max_pages, int* out_page_size,
    size_t* out_total_bytes, size_t* out_fp16_equivalent_bytes
);

// ============================================================================
// Fused Kernels (fused_kernels.cu)
// ============================================================================

/**
 * Fused RMSNorm + Linear Projection.
 *   out = (x * rsqrt(mean(x²) + eps) * weight) @ proj_weight
 * Avoids materialising the normalised intermediate tensor.
 */
int fused_rmsnorm_linear(
    float* output, const float* input,
    const float* norm_weight, const float* proj_weight,
    int batch_size, int hidden_dim, int out_dim, float eps
);

/**
 * Fused QKV Projection: q, k, v = x @ Wq, x @ Wk, x @ Wv
 * Single kernel for all three projections with GQA head mapping.
 */
int fused_qkv_projection(
    float* q, float* k, float* v, const float* x,
    const float* wq, const float* wk, const float* wv,
    int batch_size, int seq_len, int hidden_dim,
    int num_heads, int num_kv_heads, int head_dim
);

/**
 * Fused RoPE + Attention Score: apply RoPE then Q @ K^T.
 * WARNING: O(N²) memory — use only for seq_len ≤ 512.
 */
int fused_rope_attention(
    float* scores, const float* q, const float* k,
    const float* cos, const float* sin,
    int batch_size, int seq_q, int seq_k,
    int num_heads, int num_kv_heads, int head_dim, float scale
);

/**
 * Fused SwiGLU: out = silu(gate) * up.
 */
int fused_swiglu(
    float* output, const float* gate, const float* up, int n
);

/**
 * Fused Residual Add + RMSNorm.
 *   x = x + residual; y = RMSNorm(x)
 */
int fused_add_rmsnorm(
    float* output, float* x, const float* residual,
    const float* weight, int batch_size, int hidden_dim, float eps
);

/**
 * Fused Softmax + Dropout (training).
 */
int fused_softmax_dropout(
    float* output, const float* input,
    float dropout_prob, unsigned int seed,
    int batch_size, int seq_len
);

/**
 * Fused Embedding Lookup + LayerNorm.
 */
int fused_embedding_layernorm(
    float* output, const int* input_ids,
    const float* embedding_table, const float* ln_weight, const float* ln_bias,
    int batch_size, int seq_len, int hidden_dim, float eps
);

#ifdef __cplusplus
}
#endif

#endif // CUDA_KERNELS_H
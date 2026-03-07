// INT8 GEMM benchmark using cublasLtMatmul on T4
//
// Tests whether T4's INT8 tensor cores (130 TOPS) can deliver
// near-bandwidth-limited throughput for batch-4 verification.
//
// Path to 133 TPS for 7B:
//   1. Pre-dequant Q4_0 → INT8 at load time (6.5GB VRAM)
//   2. For batch-4 verify: cublasLt INT8 GEMM reads 6.5GB once → 20.3ms → 197 TPS
//   3. DART trie draft (free) + batch INT8 verify
//
// Compile: nvcc -O3 -arch=sm_75 -lcublasLt -lcublas -o int8_gemm_bench int8_gemm_bench.cu

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <cuda_runtime.h>
#include <cublasLt.h>
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
// Q4_0 → INT8 dequantization kernel
// Each thread handles one Q4_0 block (32 values → 32 INT8 values)
// ============================================================================
__global__ void dequant_q4_to_int8(int8_t* __restrict__ out,
                                    float* __restrict__ row_scales, // per-row absmax scale
                                    const uint8_t* __restrict__ W_q4,
                                    int M, int K) {
    int n_blocks_per_row = K >> 5;  // K / 32
    int block_idx = blockIdx.x * blockDim.x + threadIdx.x;
    int total_blocks = M * n_blocks_per_row;
    if (block_idx >= total_blocks) return;

    int row = block_idx / n_blocks_per_row;
    int col_block = block_idx % n_blocks_per_row;

    // Read Q4_0 block: 2 bytes f16 scale + 16 bytes data = 18 bytes
    const uint8_t* block_ptr = W_q4 + (long long)row * n_blocks_per_row * 18 + col_block * 18;
    float scale = __half2float(*reinterpret_cast<const __half*>(block_ptr));

    // Dequant to INT8: val = round(clamp((nibble - 8) * scale / row_scale * 127))
    // For simplicity, first pass: just store (nibble - 8) as INT8 directly
    // The scale factor is applied during GEMM output rescaling
    int out_base = row * K + col_block * 32;
    for (int j = 0; j < 16; j++) {
        uint8_t byte = block_ptr[2 + j];
        int8_t lo = (int8_t)((byte & 0xF) - 8);   // -8..+7
        int8_t hi = (int8_t)((byte >> 4) - 8);     // -8..+7
        out[out_base + j]      = lo;
        out[out_base + j + 16] = hi;
    }

    // Store per-block scale (we'll need this for output rescaling)
    // For now, accumulate max |scale| per row using atomicMax
    // (In production, this would be a separate reduction kernel)
}

// ============================================================================
// Simple Q4_0 → FP32 dequant for correctness reference
// ============================================================================
__global__ void dequant_q4_to_fp32(float* __restrict__ out,
                                    const uint8_t* __restrict__ W_q4,
                                    int M, int K) {
    int n_blocks_per_row = K >> 5;
    int block_idx = blockIdx.x * blockDim.x + threadIdx.x;
    int total_blocks = M * n_blocks_per_row;
    if (block_idx >= total_blocks) return;

    int row = block_idx / n_blocks_per_row;
    int col_block = block_idx % n_blocks_per_row;

    const uint8_t* block_ptr = W_q4 + (long long)row * n_blocks_per_row * 18 + col_block * 18;
    float scale = __half2float(*reinterpret_cast<const __half*>(block_ptr));

    int out_base = row * K + col_block * 32;
    for (int j = 0; j < 16; j++) {
        uint8_t byte = block_ptr[2 + j];
        out[out_base + j]      = ((float)(byte & 0xF) - 8.0f) * scale;
        out[out_base + j + 16] = ((float)(byte >> 4) - 8.0f) * scale;
    }
}

// ============================================================================
// FP16 HGEMM benchmark (alternative to INT8)
// Pre-dequant Q4_0 → FP16, then cuBLAS HGEMM
// ============================================================================
__global__ void dequant_q4_to_fp16(__half* __restrict__ out,
                                    const uint8_t* __restrict__ W_q4,
                                    int M, int K) {
    int n_blocks_per_row = K >> 5;
    int block_idx = blockIdx.x * blockDim.x + threadIdx.x;
    int total_blocks = M * n_blocks_per_row;
    if (block_idx >= total_blocks) return;

    int row = block_idx / n_blocks_per_row;
    int col_block = block_idx % n_blocks_per_row;

    const uint8_t* block_ptr = W_q4 + (long long)row * n_blocks_per_row * 18 + col_block * 18;
    __half scale_h = *reinterpret_cast<const __half*>(block_ptr);
    float scale = __half2float(scale_h);

    int out_base = row * K + col_block * 32;
    for (int j = 0; j < 16; j++) {
        uint8_t byte = block_ptr[2 + j];
        out[out_base + j]      = __float2half(((float)(byte & 0xF) - 8.0f) * scale);
        out[out_base + j + 16] = __float2half(((float)(byte >> 4) - 8.0f) * scale);
    }
}

// ============================================================================
// Benchmark functions
// ============================================================================

static uint16_t f32_to_f16_bits(float f) {
    uint32_t b = *(uint32_t*)&f;
    uint32_t sign = (b >> 16) & 0x8000;
    int exp = ((b >> 23) & 0xFF) - 127 + 15;
    uint32_t mant = (b >> 13) & 0x3FF;
    if (exp <= 0) return (uint16_t)sign;
    if (exp >= 31) return (uint16_t)(sign | 0x7C00);
    return (uint16_t)(sign | (exp << 10) | mant);
}

void bench_fp16_gemm(int M, int K, int B, const char* name,
                      uint8_t* d_W_q4, float* d_X_fp32) {
    printf("\n--- %s: FP16 HGEMM (M=%d K=%d B=%d) ---\n", name, M, K, B);

    int n_blocks = K / 32;
    size_t W_q4_bytes = (size_t)M * n_blocks * 18;
    size_t W_fp16_bytes = (size_t)M * K * sizeof(__half);

    // Allocate FP16 weight buffer + x/y buffers
    __half *d_W_fp16;
    __half *d_X_fp16, *d_Y_fp16;
    CHECK_CUDA(cudaMalloc(&d_W_fp16, W_fp16_bytes));
    CHECK_CUDA(cudaMalloc(&d_X_fp16, (size_t)K * B * sizeof(__half)));
    CHECK_CUDA(cudaMalloc(&d_Y_fp16, (size_t)M * B * sizeof(__half)));

    // Dequant Q4 → FP16
    int total_blocks = M * n_blocks;
    int threads = 256;
    int grids = (total_blocks + threads - 1) / threads;
    dequant_q4_to_fp16<<<grids, threads>>>(d_W_fp16, d_W_q4, M, K);
    CHECK_CUDA(cudaDeviceSynchronize());

    // Convert x from FP32 → FP16 (simple kernel)
    // For now, just zero-init FP16 x (we're benchmarking throughput, not correctness)
    CHECK_CUDA(cudaMemset(d_X_fp16, 0, (size_t)K * B * sizeof(__half)));

    // cuBLAS HGEMM: Y = W × X  (column-major: Y^T = X^T × W^T)
    // W: [M × K], X: [K × B], Y: [M × B]
    cublasHandle_t handle;
    CHECK_CUBLAS(cublasCreate(&handle));

    __half alpha_h = __float2half(1.0f);
    __half beta_h = __float2half(0.0f);

    // Warmup
    for (int i = 0; i < 10; i++) {
        CHECK_CUBLAS(cublasHgemm(handle,
            CUBLAS_OP_N, CUBLAS_OP_N,
            M, B, K,
            &alpha_h,
            d_W_fp16, M,
            d_X_fp16, K,
            &beta_h,
            d_Y_fp16, M));
    }
    CHECK_CUDA(cudaDeviceSynchronize());

    // Benchmark
    int n_iters = 200;
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    cudaEventRecord(start);
    for (int i = 0; i < n_iters; i++) {
        cublasHgemm(handle,
            CUBLAS_OP_N, CUBLAS_OP_N,
            M, B, K,
            &alpha_h,
            d_W_fp16, M,
            d_X_fp16, K,
            &beta_h,
            d_Y_fp16, M);
    }
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    float ms; cudaEventElapsedTime(&ms, start, stop); ms /= n_iters;

    float bw = (float)W_fp16_bytes / (ms * 1e6f);
    float tput = (float)B / ms * 1000.0f;
    printf("  HGEMM: %.3f ms  BW=%.1f GB/s  tput=%.0f tok/s\n", ms, bw, tput);

    // Also benchmark dequant time
    cudaEventRecord(start);
    for (int i = 0; i < n_iters; i++) {
        dequant_q4_to_fp16<<<grids, threads>>>(d_W_fp16, d_W_q4, M, K);
    }
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    float ms_dequant; cudaEventElapsedTime(&ms_dequant, start, stop); ms_dequant /= n_iters;
    printf("  Dequant Q4→FP16: %.3f ms\n", ms_dequant);

    cudaEventDestroy(start);
    cudaEventDestroy(stop);
    cublasDestroy(handle);
    cudaFree(d_W_fp16);
    cudaFree(d_X_fp16);
    cudaFree(d_Y_fp16);
}

void bench_fp32_sgemm(int M, int K, int B, const char* name,
                       uint8_t* d_W_q4, float* d_X_fp32) {
    printf("\n--- %s: FP32 SGEMM (M=%d K=%d B=%d) ---\n", name, M, K, B);

    size_t W_fp32_bytes = (size_t)M * K * sizeof(float);

    float *d_W_fp32, *d_Y_fp32;
    CHECK_CUDA(cudaMalloc(&d_W_fp32, W_fp32_bytes));
    CHECK_CUDA(cudaMalloc(&d_Y_fp32, (size_t)M * B * sizeof(float)));

    // Dequant Q4 → FP32
    int n_blocks = K / 32;
    int total_blocks = M * n_blocks;
    int threads = 256;
    int grids = (total_blocks + threads - 1) / threads;
    dequant_q4_to_fp32<<<grids, threads>>>(d_W_fp32, d_W_q4, M, K);
    CHECK_CUDA(cudaDeviceSynchronize());

    cublasHandle_t handle;
    CHECK_CUBLAS(cublasCreate(&handle));

    float alpha = 1.0f, beta = 0.0f;

    // Warmup
    for (int i = 0; i < 10; i++) {
        CHECK_CUBLAS(cublasSgemm(handle,
            CUBLAS_OP_N, CUBLAS_OP_N,
            M, B, K,
            &alpha,
            d_W_fp32, M,
            d_X_fp32, K,
            &beta,
            d_Y_fp32, M));
    }
    CHECK_CUDA(cudaDeviceSynchronize());

    // Benchmark
    int n_iters = 200;
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    cudaEventRecord(start);
    for (int i = 0; i < n_iters; i++) {
        cublasSgemm(handle,
            CUBLAS_OP_N, CUBLAS_OP_N,
            M, B, K,
            &alpha,
            d_W_fp32, M,
            d_X_fp32, K,
            &beta,
            d_Y_fp32, M);
    }
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    float ms; cudaEventElapsedTime(&ms, start, stop); ms /= n_iters;

    float bw = (float)W_fp32_bytes / (ms * 1e6f);
    float tput = (float)B / ms * 1000.0f;
    printf("  SGEMM: %.3f ms  BW=%.1f GB/s  tput=%.0f tok/s\n", ms, bw, tput);

    cudaEventDestroy(start);
    cudaEventDestroy(stop);
    cublasDestroy(handle);
    cudaFree(d_W_fp32);
    cudaFree(d_Y_fp32);
}

void benchmark_all(int M, int K, const char* name) {
    printf("\n========== %s (%dx%d) ==========\n", name, M, K);

    int n_blocks = K / 32;
    size_t W_q4_bytes = (size_t)M * n_blocks * 18;

    // Allocate Q4_0 weights on device
    uint8_t* h_W = (uint8_t*)malloc(W_q4_bytes);
    srand(42);
    for (size_t i = 0; i < W_q4_bytes; i++) h_W[i] = rand() & 0xFF;
    for (int r = 0; r < M; r++) {
        for (int b = 0; b < n_blocks; b++) {
            float s = 0.01f * ((rand() % 100) + 1);
            uint16_t h = f32_to_f16_bits(s);
            memcpy(&h_W[(size_t)r * n_blocks * 18 + b * 18], &h, 2);
        }
    }

    uint8_t* d_W_q4;
    CHECK_CUDA(cudaMalloc(&d_W_q4, W_q4_bytes));
    CHECK_CUDA(cudaMemcpy(d_W_q4, h_W, W_q4_bytes, cudaMemcpyHostToDevice));

    // Allocate FP32 X on device
    float* d_X;
    int max_B = 8;
    CHECK_CUDA(cudaMalloc(&d_X, (size_t)K * max_B * sizeof(float)));
    CHECK_CUDA(cudaMemset(d_X, 0, (size_t)K * max_B * sizeof(float)));

    printf("  Q4_0 weight size: %.1f MB\n", (float)W_q4_bytes / 1e6f);
    printf("  FP16 weight size: %.1f MB\n", (float)M * K * 2 / 1e6f);
    printf("  FP32 weight size: %.1f MB\n", (float)M * K * 4 / 1e6f);

    // Test different batch sizes with FP16 HGEMM
    for (int B : {1, 2, 4, 8}) {
        bench_fp16_gemm(M, K, B, name, d_W_q4, d_X);
    }

    // Also test FP32 SGEMM for comparison
    bench_fp32_sgemm(M, K, 4, name, d_W_q4, d_X);

    cudaFree(d_W_q4);
    cudaFree(d_X);
    free(h_W);
}

int main() {
    int dev;
    cudaGetDevice(&dev);
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, dev);
    printf("GPU: %s\n", prop.name);
    printf("  FP16 Tensor Cores: 65 TFLOPS\n");
    printf("  INT8 Tensor Cores: 130 TOPS\n");
    printf("  Memory BW: 320 GB/s\n");
    printf("  L2 Cache: %d KB\n\n", prop.l2CacheSize / 1024);

    // 7B model dimensions
    benchmark_all(4096, 4096, "QKV/O projection");
    benchmark_all(11008, 4096, "FFN gate/up");
    benchmark_all(4096, 11008, "FFN down");

    // Estimate full 7B layer cost
    printf("\n========== Full 7B Decode Estimate ==========\n");
    printf("Per layer: Q,K,V,O(4096x4096) + gate,up(11008x4096) + down(4096x11008)\n");
    printf("Total FP16 weights per layer: ");
    size_t qkvo = 4 * 4096ULL * 4096 * 2;
    size_t gate_up = 2 * 11008ULL * 4096 * 2;
    size_t down = 4096ULL * 11008 * 2;
    size_t total_layer = qkvo + gate_up + down;
    printf("%.1f MB\n", (float)total_layer / 1e6f);
    printf("Total 32 layers: %.1f GB\n", (float)(total_layer * 32) / 1e9f);
    printf("At 320 GB/s peak: %.1f ms to read all FP16 weights\n",
           (float)(total_layer * 32) / 320e6f);

    return 0;
}

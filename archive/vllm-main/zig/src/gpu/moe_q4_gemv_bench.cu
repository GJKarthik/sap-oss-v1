// MoE Q4_0 GEMV Microbenchmark — single-vector and batched (K vectors)
// Tests MoE-sized matrices: 768×2048 (gate/up), 2048×768 (down)
// Compile: nvcc -O3 -arch=sm_75 moe_q4_gemv_bench.cu -o moe_q4_gemv_bench -lcublas
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <cublas_v2.h>

// ============================================================================
// Kernel 1: Single-vector Q4_0 GEMV (existing optimized kernel)
// y[M] = W_q4[M×K] @ x[K]
// ============================================================================
extern "C"
__global__ void q4_0_gemv(float* __restrict__ y,
                          const uint8_t* __restrict__ W,
                          const float* __restrict__ x,
                          int M, int K) {
    extern __shared__ float x_smem[];
    int tid = threadIdx.x;
    int n_blocks_per_row = K >> 5;

    for (int idx = tid; idx < K; idx += 256) {
        int padded = idx + (idx >> 5);
        x_smem[padded] = __ldg(&x[idx]);
    }
    __syncthreads();

    int tx = tid & 31;
    int ty = tid >> 5;
    int row = blockIdx.x * 8 + ty;
    if (row >= M) return;

    const uint8_t* W_row = W + (long long)row * n_blocks_per_row * 18;

    float acc = 0.0f;
    for (int b = tx; b < n_blocks_per_row; b += 32) {
        const uint8_t* block_ptr = W_row + b * 18;
        float scale = __half2float(*reinterpret_cast<const __half*>(block_ptr));
        float neg8_scale = scale * (-8.0f);
        int x_base = b * 33;

        const uint16_t* data_u16 = reinterpret_cast<const uint16_t*>(block_ptr + 2);
        #pragma unroll
        for (int j = 0; j < 8; j++) {
            uint16_t val = __ldg(&data_u16[j]);
            uint8_t b0 = val & 0xFF;
            uint8_t b1 = val >> 8;
            acc += (float)(b0 & 0xF) * scale + neg8_scale * x_smem[x_base + j*4];
            // Fix: proper FMA
            float w0 = (float)(b0 & 0xF) * scale + neg8_scale;
            float w1 = (float)(b0 >> 4)  * scale + neg8_scale;
            float w2 = (float)(b1 & 0xF) * scale + neg8_scale;
            float w3 = (float)(b1 >> 4)  * scale + neg8_scale;
            acc += w0 * x_smem[x_base + j*4]
                 + w1 * x_smem[x_base + j*4 + 1]
                 + w2 * x_smem[x_base + j*4 + 2]
                 + w3 * x_smem[x_base + j*4 + 3];
        }
    }

    #pragma unroll
    for (int offset = 16; offset >= 1; offset >>= 1)
        acc += __shfl_xor_sync(0xFFFFFFFF, acc, offset);
    if (tx == 0) y[row] = acc;
}

// ============================================================================
// Kernel 2: Batched Q4_0 GEMV — K vectors × same weight matrix
// Y[M×batch_size] = W_q4[M×K] @ X[K×batch_size]
// Each block handles 8 rows, processes ALL batch vectors per weight read
// ============================================================================
extern "C"
__global__ void q4_0_gemv_batched(float* __restrict__ Y,
                                   const uint8_t* __restrict__ W,
                                   const float* __restrict__ X,
                                   int M, int K, int batch_size) {
    // Shared memory layout: batch_size × padded_K floats
    // For MoE: K=2048, padded = 2048+64 = 2112, batch=8 → 67,584 bytes (fits in 48KB? No!)
    // Alternative: process one batch vector at a time in shared memory
    extern __shared__ float smem[];

    int tid = threadIdx.x;
    int n_blocks_per_row = K >> 5;
    int padded_K = K + (K >> 5);  // K + K/32

    int tx = tid & 31;
    int ty = tid >> 5;
    int row = blockIdx.x * 8 + ty;

    // For each batch vector
    for (int bi = 0; bi < batch_size; bi++) {
        // Load x[bi] into shared memory
        const float* x_bi = X + (long long)bi * K;
        for (int idx = tid; idx < K; idx += 256) {
            int padded = idx + (idx >> 5);
            smem[padded] = __ldg(&x_bi[idx]);
        }
        __syncthreads();

        if (row < M) {
            const uint8_t* W_row = W + (long long)row * n_blocks_per_row * 18;

            float acc = 0.0f;
            for (int b = tx; b < n_blocks_per_row; b += 32) {
                const uint8_t* block_ptr = W_row + b * 18;
                float scale = __half2float(*reinterpret_cast<const __half*>(block_ptr));
                float neg8_scale = scale * (-8.0f);
                int x_base = b * 33;

                const uint16_t* data_u16 = reinterpret_cast<const uint16_t*>(block_ptr + 2);
                #pragma unroll
                for (int j = 0; j < 8; j++) {
                    uint16_t val = __ldg(&data_u16[j]);
                    uint8_t b0 = val & 0xFF;
                    uint8_t b1 = val >> 8;
                    float w0 = (float)(b0 & 0xF) * scale + neg8_scale;
                    float w1 = (float)(b0 >> 4)  * scale + neg8_scale;
                    float w2 = (float)(b1 & 0xF) * scale + neg8_scale;
                    float w3 = (float)(b1 >> 4)  * scale + neg8_scale;
                    acc += w0 * smem[x_base + j*4]
                         + w1 * smem[x_base + j*4 + 1]
                         + w2 * smem[x_base + j*4 + 2]
                         + w3 * smem[x_base + j*4 + 3];
                }
            }

            #pragma unroll
            for (int offset = 16; offset >= 1; offset >>= 1)
                acc += __shfl_xor_sync(0xFFFFFFFF, acc, offset);
            if (tx == 0) Y[bi * M + row] = acc;
        }
        __syncthreads();  // Ensure all threads done before next batch
    }
}

// ============================================================================
// Kernel 3: Batched Q4_0 GEMV — weight-stationary (read weight once, apply to K vectors)
// Each thread accumulates K partial products for ALL batch vectors
// Uses registers to hold per-batch accumulators
// ============================================================================
template<int BATCH_MAX>
__global__ void q4_0_gemv_batch_ws(float* __restrict__ Y,
                                    const uint8_t* __restrict__ W,
                                    const float* __restrict__ X,
                                    int M, int K, int batch_size) {
    // Shared memory: batch_size × padded_K
    // For small K (768 or 2048) and small batch (≤12), this fits
    extern __shared__ float smem[];

    int tid = threadIdx.x;
    int n_blocks_per_row = K >> 5;
    int padded_K = K + (K >> 5);

    int tx = tid & 31;
    int ty = tid >> 5;
    int row = blockIdx.x * 8 + ty;

    // Load ALL batch vectors into shared memory
    // Layout: smem[bi * padded_K + padded_idx]
    for (int bi = 0; bi < batch_size; bi++) {
        const float* x_bi = X + (long long)bi * K;
        for (int idx = tid; idx < K; idx += 256) {
            int padded = idx + (idx >> 5);
            smem[bi * padded_K + padded] = __ldg(&x_bi[idx]);
        }
    }
    __syncthreads();

    if (row >= M) return;

    const uint8_t* W_row = W + (long long)row * n_blocks_per_row * 18;

    // Register accumulators for each batch vector
    float acc[BATCH_MAX];
    for (int bi = 0; bi < batch_size; bi++) acc[bi] = 0.0f;

    // Single pass over weights — apply to all batch vectors
    for (int b = tx; b < n_blocks_per_row; b += 32) {
        const uint8_t* block_ptr = W_row + b * 18;
        float scale = __half2float(*reinterpret_cast<const __half*>(block_ptr));
        float neg8_scale = scale * (-8.0f);
        int x_offset = b * 33;

        const uint16_t* data_u16 = reinterpret_cast<const uint16_t*>(block_ptr + 2);
        #pragma unroll
        for (int j = 0; j < 8; j++) {
            uint16_t val = __ldg(&data_u16[j]);
            uint8_t b0 = val & 0xFF;
            uint8_t b1 = val >> 8;
            float w0 = (float)(b0 & 0xF) * scale + neg8_scale;
            float w1 = (float)(b0 >> 4)  * scale + neg8_scale;
            float w2 = (float)(b1 & 0xF) * scale + neg8_scale;
            float w3 = (float)(b1 >> 4)  * scale + neg8_scale;

            int base = x_offset + j * 4;
            // Apply dequantized weights to ALL batch vectors
            for (int bi = 0; bi < batch_size; bi++) {
                int smem_base = bi * padded_K + base;
                acc[bi] += w0 * smem[smem_base]
                         + w1 * smem[smem_base + 1]
                         + w2 * smem[smem_base + 2]
                         + w3 * smem[smem_base + 3];
            }
        }
    }

    // Reduction + store for each batch vector
    for (int bi = 0; bi < batch_size; bi++) {
        float val = acc[bi];
        #pragma unroll
        for (int offset = 16; offset >= 1; offset >>= 1)
            val += __shfl_xor_sync(0xFFFFFFFF, val, offset);
        if (tx == 0) Y[bi * M + row] = val;
    }
}

// ============================================================================
// Dequant + HGEMM reference (current approach)
// ============================================================================
__global__ void dequant_q4_to_fp16(half* __restrict__ out,
                                    const uint8_t* __restrict__ W,
                                    int M, int K) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    int total = M * K;
    if (idx >= total) return;

    int row = idx / K;
    int col = idx % K;
    int blk = col / 32;
    int in_blk = col % 32;
    int n_blocks_per_row = K / 32;

    const uint8_t* block_ptr = W + (long long)row * n_blocks_per_row * 18 + blk * 18;
    float scale = __half2float(*reinterpret_cast<const __half*>(block_ptr));

    int byte_idx = in_blk / 2;
    uint8_t byte_val = block_ptr[2 + byte_idx];
    int nibble = (in_blk & 1) ? (byte_val >> 4) : (byte_val & 0xF);
    float val = ((float)nibble - 8.0f) * scale;
    out[idx] = __float2half(val);
}

// ============================================================================
// Benchmark harness
// ============================================================================
void bench_single(const char* name, int M, int K, int warmup, int iters) {
    int n_blocks_per_row = K / 32;
    int row_bytes = n_blocks_per_row * 18;
    int shared_bytes = (K + K/32) * 4;
    int grid = (M + 7) / 8;

    float *d_y; uint8_t *d_W; float *d_x;
    cudaMalloc(&d_y, M * sizeof(float));
    cudaMalloc(&d_x, K * sizeof(float));
    cudaMalloc(&d_W, (size_t)M * row_bytes);
    cudaMemset(d_W, 0x42, (size_t)M * row_bytes);  // Non-zero weights
    cudaMemset(d_x, 0, K * sizeof(float));

    // Warmup
    for (int i = 0; i < warmup; i++)
        q4_0_gemv<<<grid, 256, shared_bytes>>>(d_y, d_W, d_x, M, K);
    cudaDeviceSynchronize();

    cudaEvent_t t0, t1;
    cudaEventCreate(&t0); cudaEventCreate(&t1);
    cudaEventRecord(t0);
    for (int i = 0; i < iters; i++)
        q4_0_gemv<<<grid, 256, shared_bytes>>>(d_y, d_W, d_x, M, K);
    cudaEventRecord(t1);
    cudaEventSynchronize(t1);

    float ms;
    cudaEventElapsedTime(&ms, t0, t1);
    float avg = ms / iters;
    float weight_bytes = (float)M * row_bytes;
    float bw = (weight_bytes / (avg * 1e-3)) / 1e9;

    printf("  %-35s: %7.3f ms  BW=%5.1f GB/s\n", name, avg, bw);

    cudaFree(d_y); cudaFree(d_x); cudaFree(d_W);
    cudaEventDestroy(t0); cudaEventDestroy(t1);
}

void bench_batched(const char* name, int M, int K, int batch, int warmup, int iters) {
    int n_blocks_per_row = K / 32;
    int row_bytes = n_blocks_per_row * 18;
    int shared_bytes = (K + K/32) * 4;  // For sequential batch kernel
    int grid = (M + 7) / 8;

    float *d_Y; uint8_t *d_W; float *d_X;
    cudaMalloc(&d_Y, (size_t)batch * M * sizeof(float));
    cudaMalloc(&d_X, (size_t)batch * K * sizeof(float));
    cudaMalloc(&d_W, (size_t)M * row_bytes);
    cudaMemset(d_W, 0x42, (size_t)M * row_bytes);
    cudaMemset(d_X, 0, (size_t)batch * K * sizeof(float));

    // --- Method A: Sequential single GEMV launches ---
    for (int i = 0; i < warmup; i++)
        for (int bi = 0; bi < batch; bi++)
            q4_0_gemv<<<grid, 256, shared_bytes>>>(d_Y + bi*M, d_W, d_X + bi*K, M, K);
    cudaDeviceSynchronize();

    cudaEvent_t t0, t1;
    cudaEventCreate(&t0); cudaEventCreate(&t1);
    cudaEventRecord(t0);
    for (int i = 0; i < iters; i++)
        for (int bi = 0; bi < batch; bi++)
            q4_0_gemv<<<grid, 256, shared_bytes>>>(d_Y + bi*M, d_W, d_X + bi*K, M, K);
    cudaEventRecord(t1);
    cudaEventSynchronize(t1);

    float ms_a;
    cudaEventElapsedTime(&ms_a, t0, t1);
    float avg_a = ms_a / iters;

    // --- Method B: Batched kernel (sequential x loads, one weight pass per x) ---
    for (int i = 0; i < warmup; i++)
        q4_0_gemv_batched<<<grid, 256, shared_bytes>>>(d_Y, d_W, d_X, M, K, batch);
    cudaDeviceSynchronize();

    cudaEventRecord(t0);
    for (int i = 0; i < iters; i++)
        q4_0_gemv_batched<<<grid, 256, shared_bytes>>>(d_Y, d_W, d_X, M, K, batch);
    cudaEventRecord(t1);
    cudaEventSynchronize(t1);

    float ms_b;
    cudaEventElapsedTime(&ms_b, t0, t1);
    float avg_b = ms_b / iters;

    // --- Method C: Weight-stationary batched (read weight once, all batch in registers) ---
    int padded_K = K + K/32;
    int ws_shared = batch * padded_K * 4;  // All batch vectors in smem
    float avg_c = -1;
    if (ws_shared <= 48*1024) {  // Only if fits in 48KB shared memory
        // Use batch-specialized template
        #define BENCH_WS(B) do { \
            for (int i = 0; i < warmup; i++) \
                q4_0_gemv_batch_ws<B><<<grid, 256, ws_shared>>>(d_Y, d_W, d_X, M, K, batch); \
            cudaDeviceSynchronize(); \
            cudaEventRecord(t0); \
            for (int i = 0; i < iters; i++) \
                q4_0_gemv_batch_ws<B><<<grid, 256, ws_shared>>>(d_Y, d_W, d_X, M, K, batch); \
            cudaEventRecord(t1); \
            cudaEventSynchronize(t1); \
            float ms_c; \
            cudaEventElapsedTime(&ms_c, t0, t1); \
            avg_c = ms_c / iters; \
        } while(0)

        if (batch <= 1) BENCH_WS(1);
        else if (batch <= 4) BENCH_WS(4);
        else if (batch <= 8) BENCH_WS(8);
        else BENCH_WS(12);
    }

    float weight_bytes = (float)M * row_bytes;
    printf("  K=%-2d  %-28s:\n", batch, name);
    printf("        Sequential launches : %7.3f ms  (%.3f ms/vec, BW=%.1f GB/s)\n",
           avg_a, avg_a/batch, (weight_bytes*batch / (avg_a*1e-3)) / 1e9);
    printf("        Batched kernel      : %7.3f ms  (%.3f ms/vec, BW=%.1f GB/s)\n",
           avg_b, avg_b/batch, (weight_bytes*batch / (avg_b*1e-3)) / 1e9);
    if (avg_c > 0) {
        printf("        Weight-stationary   : %7.3f ms  (%.3f ms/vec, BW=%.1f GB/s) ← weight read once\n",
               avg_c, avg_c/batch, (weight_bytes / (avg_c*1e-3)) / 1e9);
    } else {
        printf("        Weight-stationary   : SKIP (shared mem %d > 48KB)\n", ws_shared);
    }

    cudaFree(d_Y); cudaFree(d_X); cudaFree(d_W);
    cudaEventDestroy(t0); cudaEventDestroy(t1);
}

void bench_dequant_hgemm(const char* name, int M, int K, int batch, int warmup, int iters) {
    int n_blocks_per_row = K / 32;
    int row_bytes = n_blocks_per_row * 18;

    uint8_t *d_W; half *d_W_fp16; half *d_X_fp16, *d_Y_fp16;
    cudaMalloc(&d_W, (size_t)M * row_bytes);
    cudaMalloc(&d_W_fp16, (size_t)M * K * sizeof(half));
    cudaMalloc(&d_X_fp16, (size_t)batch * K * sizeof(half));
    cudaMalloc(&d_Y_fp16, (size_t)batch * M * sizeof(half));
    cudaMemset(d_W, 0x42, (size_t)M * row_bytes);

    int dequant_threads = 256;
    int dequant_blocks = (M * K + dequant_threads - 1) / dequant_threads;

    cublasHandle_t handle;
    cublasCreate(&handle);
    cublasSetMathMode(handle, CUBLAS_TENSOR_OP_MATH);

    half alpha_h = __float2half(1.0f);
    half beta_h = __float2half(0.0f);

    // Warmup
    for (int i = 0; i < warmup; i++) {
        dequant_q4_to_fp16<<<dequant_blocks, dequant_threads>>>(d_W_fp16, d_W, M, K);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N,
                     M, batch, K, &alpha_h, d_W_fp16, K, d_X_fp16, K, &beta_h, d_Y_fp16, M);
    }
    cudaDeviceSynchronize();

    cudaEvent_t t0, t1, t_mid;
    cudaEventCreate(&t0); cudaEventCreate(&t1); cudaEventCreate(&t_mid);

    // Time dequant only
    cudaEventRecord(t0);
    for (int i = 0; i < iters; i++)
        dequant_q4_to_fp16<<<dequant_blocks, dequant_threads>>>(d_W_fp16, d_W, M, K);
    cudaEventRecord(t1);
    cudaEventSynchronize(t1);
    float ms_dequant;
    cudaEventElapsedTime(&ms_dequant, t0, t1);

    // Time HGEMM only
    cudaEventRecord(t0);
    for (int i = 0; i < iters; i++)
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N,
                     M, batch, K, &alpha_h, d_W_fp16, K, d_X_fp16, K, &beta_h, d_Y_fp16, M);
    cudaEventRecord(t1);
    cudaEventSynchronize(t1);
    float ms_hgemm;
    cudaEventElapsedTime(&ms_hgemm, t0, t1);

    // Time dequant + HGEMM combined
    cudaEventRecord(t0);
    for (int i = 0; i < iters; i++) {
        dequant_q4_to_fp16<<<dequant_blocks, dequant_threads>>>(d_W_fp16, d_W, M, K);
        cublasHgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N,
                     M, batch, K, &alpha_h, d_W_fp16, K, d_X_fp16, K, &beta_h, d_Y_fp16, M);
    }
    cudaEventRecord(t1);
    cudaEventSynchronize(t1);
    float ms_total;
    cudaEventElapsedTime(&ms_total, t0, t1);

    printf("  K=%-2d  %-28s (dequant+HGEMM):\n", batch, name);
    printf("        Dequant only   : %7.3f ms\n", ms_dequant / iters);
    printf("        HGEMM only     : %7.3f ms\n", ms_hgemm / iters);
    printf("        Dequant+HGEMM  : %7.3f ms  (%.3f ms/vec)\n",
           ms_total / iters, ms_total / iters / batch);

    cublasDestroy(handle);
    cudaFree(d_W); cudaFree(d_W_fp16); cudaFree(d_X_fp16); cudaFree(d_Y_fp16);
    cudaEventDestroy(t0); cudaEventDestroy(t1); cudaEventDestroy(t_mid);
}

// ============================================================================
// Full MoE layer simulation: 8 experts × 3 matrices (gate, up, down)
// ============================================================================
void bench_full_moe_layer(int dim, int eff, int topk, int batch,
                          int warmup, int iters) {
    int M_gate = eff, K_gate = dim;    // gate: eff×dim
    int M_down = dim, K_down = eff;    // down: dim×eff

    int nb_gate = K_gate / 32;
    int nb_down = K_down / 32;
    int gate_row_bytes = nb_gate * 18;
    int down_row_bytes = nb_down * 18;
    int shared_gate = (K_gate + K_gate/32) * 4;
    int shared_down = (K_down + K_down/32) * 4;
    int grid_gate = (M_gate + 7) / 8;
    int grid_down = (M_down + 7) / 8;

    // Allocate for topk experts (gate/up share same dims)
    uint8_t *d_gate[16], *d_up[16], *d_down[16];
    float *d_x, *d_hidden, *d_scratch, *d_out;
    cudaMalloc(&d_x, dim * sizeof(float));
    cudaMalloc(&d_hidden, eff * sizeof(float));
    cudaMalloc(&d_scratch, eff * sizeof(float));
    cudaMalloc(&d_out, dim * sizeof(float));
    cudaMemset(d_x, 0, dim * sizeof(float));

    for (int e = 0; e < topk; e++) {
        cudaMalloc(&d_gate[e], (size_t)M_gate * gate_row_bytes);
        cudaMalloc(&d_up[e], (size_t)M_gate * gate_row_bytes);
        cudaMalloc(&d_down[e], (size_t)M_down * down_row_bytes);
        cudaMemset(d_gate[e], 0x42, (size_t)M_gate * gate_row_bytes);
        cudaMemset(d_up[e], 0x42, (size_t)M_gate * gate_row_bytes);
        cudaMemset(d_down[e], 0x42, (size_t)M_down * down_row_bytes);
    }

    // Warmup
    for (int i = 0; i < warmup; i++) {
        for (int e = 0; e < topk; e++) {
            q4_0_gemv<<<grid_gate, 256, shared_gate>>>(d_hidden, d_gate[e], d_x, M_gate, K_gate);
            q4_0_gemv<<<grid_gate, 256, shared_gate>>>(d_scratch, d_up[e], d_x, M_gate, K_gate);
            // SwiGLU would go here (skip for microbench)
            q4_0_gemv<<<grid_down, 256, shared_down>>>(d_out, d_down[e], d_hidden, M_down, K_down);
        }
    }
    cudaDeviceSynchronize();

    cudaEvent_t t0, t1;
    cudaEventCreate(&t0); cudaEventCreate(&t1);
    cudaEventRecord(t0);
    for (int i = 0; i < iters; i++) {
        for (int e = 0; e < topk; e++) {
            q4_0_gemv<<<grid_gate, 256, shared_gate>>>(d_hidden, d_gate[e], d_x, M_gate, K_gate);
            q4_0_gemv<<<grid_gate, 256, shared_gate>>>(d_scratch, d_up[e], d_x, M_gate, K_gate);
            q4_0_gemv<<<grid_down, 256, shared_down>>>(d_out, d_down[e], d_hidden, M_down, K_down);
        }
    }
    cudaEventRecord(t1);
    cudaEventSynchronize(t1);

    float ms;
    cudaEventElapsedTime(&ms, t0, t1);
    float avg = ms / iters;

    float total_weight_bytes = topk * (2.0f * M_gate * gate_row_bytes + M_down * down_row_bytes);
    float bw = (total_weight_bytes / (avg * 1e-3)) / 1e9;

    printf("\n  Full MoE layer (%d experts × 3 matrices, Q4 GEMV):\n", topk);
    printf("    Total: %.3f ms  (%.3f ms/expert, BW=%.1f GB/s)\n", avg, avg/topk, bw);
    printf("    Weight data: %.2f MB\n", total_weight_bytes / (1024*1024));

    for (int e = 0; e < topk; e++) {
        cudaFree(d_gate[e]); cudaFree(d_up[e]); cudaFree(d_down[e]);
    }
    cudaFree(d_x); cudaFree(d_hidden); cudaFree(d_scratch); cudaFree(d_out);
    cudaEventDestroy(t0); cudaEventDestroy(t1);
}

int main() {
    printf("MoE Q4_0 GEMV Microbenchmark (Qwen3-30B-A3B MoE dimensions)\n");
    printf("=============================================================\n");
    printf("Expert dims: gate/up = 768×2048, down = 2048×768\n");
    printf("TopK=8 experts per token, 48 layers\n\n");

    int dim = 2048, eff = 768, topk = 8;
    int warmup = 20, iters = 200;

    // Part 1: Single-vector GEMV timing per matrix
    printf("=== Part 1: Single-vector Q4_0 GEMV per matrix ===\n");
    bench_single("gate/up (768×2048)", eff, dim, warmup, iters);
    bench_single("down    (2048×768)", dim, eff, warmup, iters);

    // Also test LLaMA-7B sizes for comparison
    printf("\n  (LLaMA-7B reference):\n");
    bench_single("QKV     (4096×4096)", 4096, 4096, warmup, iters);
    bench_single("FFN     (11008×4096)", 11008, 4096, warmup, iters);

    // Part 2: Full MoE layer (8 experts × 3 matrices)
    printf("\n=== Part 2: Full MoE layer — Q4 GEMV vs dequant+HGEMM ===\n");
    bench_full_moe_layer(dim, eff, topk, 1, warmup, iters);

    // Part 3: Dequant+HGEMM reference for single matrix
    printf("\n=== Part 3: Dequant+HGEMM reference (current approach) ===\n");
    bench_dequant_hgemm("gate/up (768×2048)", eff, dim, 1, warmup, iters);
    bench_dequant_hgemm("down    (2048×768)", dim, eff, 1, warmup, iters);

    // Part 4: Batched GEMV for DART
    printf("\n=== Part 4: Batched Q4_0 GEMV (DART amortization) ===\n");
    int batch_sizes[] = {1, 4, 8, 12};
    for (int b : batch_sizes) {
        bench_batched("gate/up (768×2048)", eff, dim, b, warmup, iters);
    }

    // Part 5: Extrapolation to full forward pass
    printf("\n=== Part 5: Estimated full forward pass (48 layers) ===\n");
    printf("  (Using Part 2 timings × 48 layers + ~3ms attention/other)\n");

    printf("\nDone.\n");
    return 0;
}

// q4_0 Batched GEMM: Read weights ONCE, compute B output vectors
// Two approaches benchmarked:
//
// 1. L2-cached x[]: No shared memory for x, read from L2 cache (unlimited batch)
// 2. Unpadded smem: Remove bank-conflict padding to fit B=4 in 64KB
//
// Target: T4 (sm_75, 48KB default smem, 64KB max, 4MB L2)
// Goal: ~4× throughput over GEMV for DART speculative decode verification
//
// Compile: nvcc -O3 -arch=sm_75 -o q4_gemm_batch q4_gemm_batch.cu && ./q4_gemm_batch

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cmath>
#include <cstring>
#include <cuda_runtime.h>
#include <cuda_fp16.h>

// ============================================================================
// Baseline: Single-vector GEMV (B=1) with padded shared memory
// ============================================================================
extern "C"
__global__ void q4_0_gemv_b1(float* __restrict__ y,
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
        float neg8s = scale * (-8.0f);
        int x_base = b * 33;

        const uint16_t* data_u16 = reinterpret_cast<const uint16_t*>(block_ptr + 2);
        #pragma unroll
        for (int j = 0; j < 8; j++) {
            uint16_t val = __ldg(&data_u16[j]);
            uint8_t b0 = val & 0xFF;
            uint8_t b1 = val >> 8;
            acc += ((float)(b0 & 0xF) * scale + neg8s) * x_smem[x_base + j*4];
            acc += ((float)(b0 >> 4) * scale + neg8s) * x_smem[x_base + j*4+1];
            acc += ((float)(b1 & 0xF) * scale + neg8s) * x_smem[x_base + j*4+2];
            acc += ((float)(b1 >> 4) * scale + neg8s) * x_smem[x_base + j*4+3];
        }
    }

    #pragma unroll
    for (int offset = 16; offset >= 1; offset >>= 1)
        acc += __shfl_xor_sync(0xFFFFFFFF, acc, offset);
    if (tx == 0) y[row] = acc;
}

// ============================================================================
// Approach 1: L2-cached x[], no shared memory for x
// Weights read once from global memory, x read B times from L2 cache.
// Since x is only 16KB per vector and T4 L2 is 4MB, all B vectors stay cached.
// ============================================================================
extern "C"
__global__ void q4_0_gemm_l2_b4(float* __restrict__ y,  // [B * M] interleaved
                                  const uint8_t* __restrict__ W,
                                  const float* __restrict__ X,  // [B * K] contiguous
                                  int M, int K, int B) {
    int tid = threadIdx.x;
    int tx = tid & 31;
    int ty = tid >> 5;
    int row = blockIdx.x * 8 + ty;
    if (row >= M) return;

    int n_blocks_per_row = K >> 5;
    const uint8_t* W_row = W + (long long)row * n_blocks_per_row * 18;

    // Accumulators for each batch element
    float acc0 = 0.0f, acc1 = 0.0f, acc2 = 0.0f, acc3 = 0.0f;

    for (int b = tx; b < n_blocks_per_row; b += 32) {
        const uint8_t* block_ptr = W_row + b * 18;
        float scale = __half2float(*reinterpret_cast<const __half*>(block_ptr));
        float neg8s = scale * (-8.0f);
        int x_off = b << 5;  // b * 32

        const uint16_t* data_u16 = reinterpret_cast<const uint16_t*>(block_ptr + 2);

        // Dequantize 32 weight values and multiply with all B x vectors
        #pragma unroll
        for (int j = 0; j < 8; j++) {
            uint16_t val = __ldg(&data_u16[j]);
            uint8_t byte0 = val & 0xFF;
            uint8_t byte1 = val >> 8;

            float w0 = (float)(byte0 & 0xF) * scale + neg8s;
            float w1 = (float)(byte0 >> 4) * scale + neg8s;
            float w2 = (float)(byte1 & 0xF) * scale + neg8s;
            float w3 = (float)(byte1 >> 4) * scale + neg8s;

            int xi = x_off + j * 4;

            // Batch 0
            acc0 += w0 * __ldg(&X[xi]);
            acc0 += w1 * __ldg(&X[xi+1]);
            acc0 += w2 * __ldg(&X[xi+2]);
            acc0 += w3 * __ldg(&X[xi+3]);

            // Batch 1
            if (B > 1) {
                acc1 += w0 * __ldg(&X[K + xi]);
                acc1 += w1 * __ldg(&X[K + xi+1]);
                acc1 += w2 * __ldg(&X[K + xi+2]);
                acc1 += w3 * __ldg(&X[K + xi+3]);
            }

            // Batch 2
            if (B > 2) {
                acc2 += w0 * __ldg(&X[2*K + xi]);
                acc2 += w1 * __ldg(&X[2*K + xi+1]);
                acc2 += w2 * __ldg(&X[2*K + xi+2]);
                acc2 += w3 * __ldg(&X[2*K + xi+3]);
            }

            // Batch 3
            if (B > 3) {
                acc3 += w0 * __ldg(&X[3*K + xi]);
                acc3 += w1 * __ldg(&X[3*K + xi+1]);
                acc3 += w2 * __ldg(&X[3*K + xi+2]);
                acc3 += w3 * __ldg(&X[3*K + xi+3]);
            }
        }
    }

    // Warp shuffle reduction
    #pragma unroll
    for (int offset = 16; offset >= 1; offset >>= 1) {
        acc0 += __shfl_xor_sync(0xFFFFFFFF, acc0, offset);
        if (B > 1) acc1 += __shfl_xor_sync(0xFFFFFFFF, acc1, offset);
        if (B > 2) acc2 += __shfl_xor_sync(0xFFFFFFFF, acc2, offset);
        if (B > 3) acc3 += __shfl_xor_sync(0xFFFFFFFF, acc3, offset);
    }

    if (tx == 0) {
        y[row] = acc0;
        if (B > 1) y[M + row] = acc1;
        if (B > 2) y[2*M + row] = acc2;
        if (B > 3) y[3*M + row] = acc3;
    }
}

// ============================================================================
// Approach 2: Template version with compile-time B for better optimization
// ============================================================================
template <int BATCH>
__global__ void q4_0_gemm_l2(float* __restrict__ y,
                              const uint8_t* __restrict__ W,
                              const float* __restrict__ X,
                              int M, int K) {
    int tid = threadIdx.x;
    int tx = tid & 31;
    int ty = tid >> 5;
    int row = blockIdx.x * 8 + ty;
    if (row >= M) return;

    int n_blocks_per_row = K >> 5;
    const uint8_t* W_row = W + (long long)row * n_blocks_per_row * 18;

    float acc[BATCH];
    #pragma unroll
    for (int bi = 0; bi < BATCH; bi++) acc[bi] = 0.0f;

    for (int b = tx; b < n_blocks_per_row; b += 32) {
        const uint8_t* block_ptr = W_row + b * 18;
        float scale = __half2float(*reinterpret_cast<const __half*>(block_ptr));
        float neg8s = scale * (-8.0f);
        int x_off = b << 5;

        const uint16_t* data_u16 = reinterpret_cast<const uint16_t*>(block_ptr + 2);

        #pragma unroll
        for (int j = 0; j < 8; j++) {
            uint16_t val = __ldg(&data_u16[j]);
            uint8_t byte0 = val & 0xFF;
            uint8_t byte1 = val >> 8;

            float w0 = (float)(byte0 & 0xF) * scale + neg8s;
            float w1 = (float)(byte0 >> 4) * scale + neg8s;
            float w2 = (float)(byte1 & 0xF) * scale + neg8s;
            float w3 = (float)(byte1 >> 4) * scale + neg8s;

            int xi = x_off + j * 4;

            #pragma unroll
            for (int bi = 0; bi < BATCH; bi++) {
                int base = bi * K + xi;
                acc[bi] += w0 * __ldg(&X[base]);
                acc[bi] += w1 * __ldg(&X[base+1]);
                acc[bi] += w2 * __ldg(&X[base+2]);
                acc[bi] += w3 * __ldg(&X[base+3]);
            }
        }
    }

    #pragma unroll
    for (int offset = 16; offset >= 1; offset >>= 1) {
        #pragma unroll
        for (int bi = 0; bi < BATCH; bi++)
            acc[bi] += __shfl_xor_sync(0xFFFFFFFF, acc[bi], offset);
    }

    if (tx == 0) {
        #pragma unroll
        for (int bi = 0; bi < BATCH; bi++)
            y[bi * M + row] = acc[bi];
    }
}

// ============================================================================
// Approach 3: Hybrid — x[0] in shared memory, rest from L2
// First batch element gets fast smem access, others read from L2 cache
// ============================================================================
template <int BATCH>
__global__ void q4_0_gemm_hybrid(float* __restrict__ y,
                                  const uint8_t* __restrict__ W,
                                  const float* __restrict__ X,
                                  int M, int K) {
    extern __shared__ float x0_smem[];
    int tid = threadIdx.x;
    int n_blocks_per_row = K >> 5;

    // Load x[0] into padded shared memory (same as GEMV baseline)
    for (int idx = tid; idx < K; idx += 256) {
        int padded = idx + (idx >> 5);
        x0_smem[padded] = __ldg(&X[idx]);
    }
    __syncthreads();

    int tx = tid & 31;
    int ty = tid >> 5;
    int row = blockIdx.x * 8 + ty;
    if (row >= M) return;

    const uint8_t* W_row = W + (long long)row * n_blocks_per_row * 18;

    float acc[BATCH];
    #pragma unroll
    for (int bi = 0; bi < BATCH; bi++) acc[bi] = 0.0f;

    for (int b = tx; b < n_blocks_per_row; b += 32) {
        const uint8_t* block_ptr = W_row + b * 18;
        float scale = __half2float(*reinterpret_cast<const __half*>(block_ptr));
        float neg8s = scale * (-8.0f);
        int x_off = b << 5;
        int x_smem_base = b * 33;  // padded for smem

        const uint16_t* data_u16 = reinterpret_cast<const uint16_t*>(block_ptr + 2);

        #pragma unroll
        for (int j = 0; j < 8; j++) {
            uint16_t val = __ldg(&data_u16[j]);
            uint8_t byte0 = val & 0xFF;
            uint8_t byte1 = val >> 8;

            float w0 = (float)(byte0 & 0xF) * scale + neg8s;
            float w1 = (float)(byte0 >> 4) * scale + neg8s;
            float w2 = (float)(byte1 & 0xF) * scale + neg8s;
            float w3 = (float)(byte1 >> 4) * scale + neg8s;

            int si = x_smem_base + j * 4;  // padded index for smem
            int gi = x_off + j * 4;        // global index

            // Batch 0: from shared memory (fast, bank-conflict-free)
            acc[0] += w0 * x0_smem[si];
            acc[0] += w1 * x0_smem[si+1];
            acc[0] += w2 * x0_smem[si+2];
            acc[0] += w3 * x0_smem[si+3];

            // Batches 1..B-1: from L2 cache
            #pragma unroll
            for (int bi = 1; bi < BATCH; bi++) {
                int base = bi * K + gi;
                acc[bi] += w0 * __ldg(&X[base]);
                acc[bi] += w1 * __ldg(&X[base+1]);
                acc[bi] += w2 * __ldg(&X[base+2]);
                acc[bi] += w3 * __ldg(&X[base+3]);
            }
        }
    }

    #pragma unroll
    for (int offset = 16; offset >= 1; offset >>= 1) {
        #pragma unroll
        for (int bi = 0; bi < BATCH; bi++)
            acc[bi] += __shfl_xor_sync(0xFFFFFFFF, acc[bi], offset);
    }

    if (tx == 0) {
        #pragma unroll
        for (int bi = 0; bi < BATCH; bi++)
            y[bi * M + row] = acc[bi];
    }
}

// ============================================================================
// Host benchmark
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

void benchmark_config(int M, int K, const char* name) {
    int n_blocks = K / 32;
    size_t W_bytes = (size_t)M * n_blocks * 18;
    const int B = 4;

    // Allocate host
    float* h_x = (float*)malloc(B * K * sizeof(float));
    uint8_t* h_W = (uint8_t*)malloc(W_bytes);
    float* h_y_ref = (float*)malloc(M * sizeof(float));
    float* h_y_test = (float*)malloc(B * M * sizeof(float));

    srand(42);
    for (int i = 0; i < B * K; i++) h_x[i] = (float)(rand() % 200 - 100) / 100.0f;
    for (size_t i = 0; i < W_bytes; i++) h_W[i] = rand() & 0xFF;
    for (int r = 0; r < M; r++) {
        for (int b = 0; b < n_blocks; b++) {
            float s = 0.01f * ((rand() % 100) + 1);
            uint16_t h = f32_to_f16_bits(s);
            memcpy(&h_W[(size_t)r * n_blocks * 18 + b * 18], &h, 2);
        }
    }

    // Allocate device
    float *d_y_b1, *d_y_batch;
    float *d_X;
    uint8_t *d_W;
    cudaMalloc(&d_y_b1, M * sizeof(float));
    cudaMalloc(&d_y_batch, B * M * sizeof(float));
    cudaMalloc(&d_X, B * K * sizeof(float));
    cudaMalloc(&d_W, W_bytes);
    cudaMemcpy(d_W, h_W, W_bytes, cudaMemcpyHostToDevice);
    cudaMemcpy(d_X, h_x, B * K * sizeof(float), cudaMemcpyHostToDevice);

    dim3 grid((M + 7) / 8), block(256);
    int smem_b1 = (K + K / 32) * sizeof(float);

    // Warmup
    for (int i = 0; i < 10; i++) {
        q4_0_gemv_b1<<<grid, block, smem_b1>>>(d_y_b1, d_W, d_X, M, K);
        q4_0_gemm_l2<4><<<grid, block, 0>>>(d_y_batch, d_W, d_X, M, K);
        q4_0_gemm_hybrid<4><<<grid, block, smem_b1>>>(d_y_batch, d_W, d_X, M, K);
    }
    cudaDeviceSynchronize();
    cudaError_t err = cudaGetLastError();
    if (err != cudaSuccess) printf("  Launch error: %s\n", cudaGetErrorString(err));

    // Correctness check: compare batch[0] with GEMV baseline
    q4_0_gemv_b1<<<grid, block, smem_b1>>>(d_y_b1, d_W, d_X, M, K);
    q4_0_gemm_l2<4><<<grid, block, 0>>>(d_y_batch, d_W, d_X, M, K);
    cudaDeviceSynchronize();

    cudaMemcpy(h_y_ref, d_y_b1, M * sizeof(float), cudaMemcpyDeviceToHost);
    cudaMemcpy(h_y_test, d_y_batch, M * sizeof(float), cudaMemcpyDeviceToHost);

    float max_err = 0.0f;
    for (int i = 0; i < M; i++) {
        float e = fabsf(h_y_ref[i] - h_y_test[i]);
        if (e > max_err) max_err = e;
    }
    printf("\n=== %s (%dx%d) ===\n", name, M, K);
    printf("  L2 correctness: max_err=%.6f (ref[0]=%.4f test[0]=%.4f)\n",
           max_err, h_y_ref[0], h_y_test[0]);

    // Also check hybrid
    q4_0_gemm_hybrid<4><<<grid, block, smem_b1>>>(d_y_batch, d_W, d_X, M, K);
    cudaDeviceSynchronize();
    cudaMemcpy(h_y_test, d_y_batch, M * sizeof(float), cudaMemcpyDeviceToHost);
    max_err = 0.0f;
    for (int i = 0; i < M; i++) {
        float e = fabsf(h_y_ref[i] - h_y_test[i]);
        if (e > max_err) max_err = e;
    }
    printf("  Hybrid correctness: max_err=%.6f\n", max_err);

    // Benchmark
    int n_iters = 200;
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    // B=1 baseline (GEMV)
    cudaEventRecord(start);
    for (int i = 0; i < n_iters; i++)
        q4_0_gemv_b1<<<grid, block, smem_b1>>>(d_y_b1, d_W, d_X, M, K);
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    float ms_b1; cudaEventElapsedTime(&ms_b1, start, stop); ms_b1 /= n_iters;

    // L2-cached B=2
    cudaEventRecord(start);
    for (int i = 0; i < n_iters; i++)
        q4_0_gemm_l2<2><<<grid, block, 0>>>(d_y_batch, d_W, d_X, M, K);
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    float ms_l2_b2; cudaEventElapsedTime(&ms_l2_b2, start, stop); ms_l2_b2 /= n_iters;

    // L2-cached B=4
    cudaEventRecord(start);
    for (int i = 0; i < n_iters; i++)
        q4_0_gemm_l2<4><<<grid, block, 0>>>(d_y_batch, d_W, d_X, M, K);
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    float ms_l2_b4; cudaEventElapsedTime(&ms_l2_b4, start, stop); ms_l2_b4 /= n_iters;

    // Hybrid B=4 (x[0] in smem, rest in L2)
    cudaEventRecord(start);
    for (int i = 0; i < n_iters; i++)
        q4_0_gemm_hybrid<4><<<grid, block, smem_b1>>>(d_y_batch, d_W, d_X, M, K);
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    float ms_hyb_b4; cudaEventElapsedTime(&ms_hyb_b4, start, stop); ms_hyb_b4 /= n_iters;

    // L2-cached B=8
    cudaEventRecord(start);
    for (int i = 0; i < n_iters; i++)
        q4_0_gemm_l2<8><<<grid, block, 0>>>(d_y_batch, d_W, d_X, M, K);
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    float ms_l2_b8; cudaEventElapsedTime(&ms_l2_b8, start, stop); ms_l2_b8 /= n_iters;

    float bw_b1 = (float)W_bytes / (ms_b1 * 1e6f);

    printf("  B=1 GEMV (smem):   %.3f ms  BW=%.1f GB/s  tput=%.0f tok/s\n",
           ms_b1, bw_b1, 1.0f/ms_b1*1000.0f);
    printf("  B=2 L2:            %.3f ms  BW=%.1f GB/s  tput=%.0f tok/s (%.2fx)\n",
           ms_l2_b2, (float)W_bytes/(ms_l2_b2*1e6f), 2.0f/ms_l2_b2*1000.0f, (2.0f*ms_b1)/ms_l2_b2);
    printf("  B=4 L2:            %.3f ms  BW=%.1f GB/s  tput=%.0f tok/s (%.2fx)\n",
           ms_l2_b4, (float)W_bytes/(ms_l2_b4*1e6f), 4.0f/ms_l2_b4*1000.0f, (4.0f*ms_b1)/ms_l2_b4);
    printf("  B=4 Hybrid:        %.3f ms  BW=%.1f GB/s  tput=%.0f tok/s (%.2fx)\n",
           ms_hyb_b4, (float)W_bytes/(ms_hyb_b4*1e6f), 4.0f/ms_hyb_b4*1000.0f, (4.0f*ms_b1)/ms_hyb_b4);
    printf("  B=8 L2:            %.3f ms  BW=%.1f GB/s  tput=%.0f tok/s (%.2fx)\n",
           ms_l2_b8, (float)W_bytes/(ms_l2_b8*1e6f), 8.0f/ms_l2_b8*1000.0f, (8.0f*ms_b1)/ms_l2_b8);

    // Simulate full 7B layer cost
    if (M == 4096 && K == 4096) {
        // Per layer: 3×QKV(4096×4096) + O(4096×4096) + gate(11008×4096) + up(11008×4096) + down(4096×11008)
        // Here we just report the QKV/O component
        float layer_qkvo_b1 = 4 * ms_b1;
        float layer_qkvo_b4 = 4 * ms_l2_b4;
        printf("\n  Layer QKVO cost: B=1 %.3fms  B=4 %.3fms\n", layer_qkvo_b1, layer_qkvo_b4);
    }

    cudaEventDestroy(start);
    cudaEventDestroy(stop);
    cudaFree(d_y_b1); cudaFree(d_y_batch); cudaFree(d_X); cudaFree(d_W);
    free(h_x); free(h_W); free(h_y_ref); free(h_y_test);
}

int main() {
    int dev;
    cudaGetDevice(&dev);
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, dev);
    printf("GPU: %s  L2=%dKB  smem/block=%dKB\n",
           prop.name, prop.l2CacheSize/1024, prop.sharedMemPerBlock/1024);

    benchmark_config(4096, 4096, "QKV/O projection");
    benchmark_config(11008, 4096, "FFN gate/up");
    benchmark_config(4096, 11008, "FFN down");

    // Summary: estimate full 7B decode
    printf("\n=== Full 7B Layer Estimate ===\n");
    printf("  Per layer has 7 GEMV ops: Q,K,V,O (4096×4096) + gate,up (11008×4096) + down (4096×11008)\n");
    printf("  Check numbers above to compute total per-token and per-batch costs.\n");

    return 0;
}

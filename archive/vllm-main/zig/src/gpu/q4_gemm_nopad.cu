// q4_0 Batched GEMM with UNPADDED shared memory
//
// Key insight: without bank-conflict padding, B=4 × K=4096 × 4B = 64KB exactly,
// which fits in T4's max dynamic shared memory (65536 bytes).
// Bank conflict penalty is ~3% (proven in previous sessions), but B=4 amortization
// of weight reads should far outweigh this.
//
// For FFN down (K=11008): falls back to B=1 GEMV since 4×11008×4 = 176KB > 64KB.
// For QKV/O/gate/up (K=4096): B=4 fits.
//
// Compile: nvcc -O3 -arch=sm_75 -o q4_gemm_nopad q4_gemm_nopad.cu && ./q4_gemm_nopad

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cmath>
#include <cstring>
#include <cuda_runtime.h>
#include <cuda_fp16.h>

// ============================================================================
// Baseline B=1 with padded shared memory (our production kernel)
// ============================================================================
extern "C"
__global__ void q4_0_gemv_padded(float* __restrict__ y,
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
        int x_base = b * 33;  // padded stride

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
// B=4 with UNPADDED shared memory (64KB for K=4096)
// x[0..3] packed contiguously: smem[bi * K + idx]
// ============================================================================
extern "C"
__global__ void q4_0_gemm_b4_nopad(float* __restrict__ y,  // [4 * M]
                                     const uint8_t* __restrict__ W,
                                     const float* __restrict__ X,  // [4 * K]
                                     int M, int K) {
    extern __shared__ float smem[];  // 4 * K floats = 64KB for K=4096
    int tid = threadIdx.x;
    int n_blocks_per_row = K >> 5;

    // Cooperative load: all 4 x vectors into unpadded shared memory
    // Each thread loads multiple elements across all 4 vectors
    for (int idx = tid; idx < K; idx += 256) {
        smem[idx]         = __ldg(&X[idx]);          // x[0]
        smem[K + idx]     = __ldg(&X[K + idx]);      // x[1]
        smem[2*K + idx]   = __ldg(&X[2*K + idx]);    // x[2]
        smem[3*K + idx]   = __ldg(&X[3*K + idx]);    // x[3]
    }
    __syncthreads();

    int tx = tid & 31;
    int ty = tid >> 5;
    int row = blockIdx.x * 8 + ty;
    if (row >= M) return;

    const uint8_t* W_row = W + (long long)row * n_blocks_per_row * 18;
    float acc0 = 0.0f, acc1 = 0.0f, acc2 = 0.0f, acc3 = 0.0f;

    for (int b = tx; b < n_blocks_per_row; b += 32) {
        const uint8_t* block_ptr = W_row + b * 18;
        float scale = __half2float(*reinterpret_cast<const __half*>(block_ptr));
        float neg8s = scale * (-8.0f);
        int x_base = b << 5;  // b * 32 (unpadded)

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

            int xi = x_base + j * 4;

            // Batch 0
            acc0 += w0 * smem[xi];
            acc0 += w1 * smem[xi+1];
            acc0 += w2 * smem[xi+2];
            acc0 += w3 * smem[xi+3];

            // Batch 1
            acc1 += w0 * smem[K + xi];
            acc1 += w1 * smem[K + xi+1];
            acc1 += w2 * smem[K + xi+2];
            acc1 += w3 * smem[K + xi+3];

            // Batch 2
            acc2 += w0 * smem[2*K + xi];
            acc2 += w1 * smem[2*K + xi+1];
            acc2 += w2 * smem[2*K + xi+2];
            acc2 += w3 * smem[2*K + xi+3];

            // Batch 3
            acc3 += w0 * smem[3*K + xi];
            acc3 += w1 * smem[3*K + xi+1];
            acc3 += w2 * smem[3*K + xi+2];
            acc3 += w3 * smem[3*K + xi+3];
        }
    }

    // Warp shuffle reduction
    #pragma unroll
    for (int offset = 16; offset >= 1; offset >>= 1) {
        acc0 += __shfl_xor_sync(0xFFFFFFFF, acc0, offset);
        acc1 += __shfl_xor_sync(0xFFFFFFFF, acc1, offset);
        acc2 += __shfl_xor_sync(0xFFFFFFFF, acc2, offset);
        acc3 += __shfl_xor_sync(0xFFFFFFFF, acc3, offset);
    }

    if (tx == 0) {
        y[row]       = acc0;
        y[M + row]   = acc1;
        y[2*M + row] = acc2;
        y[3*M + row] = acc3;
    }
}

// ============================================================================
// B=2 with UNPADDED shared memory (32KB for K=4096 — fits in default 48KB)
// ============================================================================
extern "C"
__global__ void q4_0_gemm_b2_nopad(float* __restrict__ y,  // [2 * M]
                                     const uint8_t* __restrict__ W,
                                     const float* __restrict__ X,  // [2 * K]
                                     int M, int K) {
    extern __shared__ float smem[];  // 2 * K floats
    int tid = threadIdx.x;
    int n_blocks_per_row = K >> 5;

    for (int idx = tid; idx < K; idx += 256) {
        smem[idx]       = __ldg(&X[idx]);
        smem[K + idx]   = __ldg(&X[K + idx]);
    }
    __syncthreads();

    int tx = tid & 31;
    int ty = tid >> 5;
    int row = blockIdx.x * 8 + ty;
    if (row >= M) return;

    const uint8_t* W_row = W + (long long)row * n_blocks_per_row * 18;
    float acc0 = 0.0f, acc1 = 0.0f;

    for (int b = tx; b < n_blocks_per_row; b += 32) {
        const uint8_t* block_ptr = W_row + b * 18;
        float scale = __half2float(*reinterpret_cast<const __half*>(block_ptr));
        float neg8s = scale * (-8.0f);
        int x_base = b << 5;

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

            int xi = x_base + j * 4;

            acc0 += w0 * smem[xi];
            acc0 += w1 * smem[xi+1];
            acc0 += w2 * smem[xi+2];
            acc0 += w3 * smem[xi+3];

            acc1 += w0 * smem[K + xi];
            acc1 += w1 * smem[K + xi+1];
            acc1 += w2 * smem[K + xi+2];
            acc1 += w3 * smem[K + xi+3];
        }
    }

    #pragma unroll
    for (int offset = 16; offset >= 1; offset >>= 1) {
        acc0 += __shfl_xor_sync(0xFFFFFFFF, acc0, offset);
        acc1 += __shfl_xor_sync(0xFFFFFFFF, acc1, offset);
    }

    if (tx == 0) {
        y[row]     = acc0;
        y[M + row] = acc1;
    }
}

// ============================================================================
// B=4 via 2 passes of B=2 (reads weights twice, but stays in 32KB smem)
// ============================================================================
void q4_0_gemm_b4_2pass(float* d_y, const uint8_t* d_W, const float* d_X,
                          int M, int K, cudaStream_t stream = 0) {
    dim3 grid((M + 7) / 8), block(256);
    int smem = 2 * K * sizeof(float);

    // Pass 1: x[0], x[1] → y[0], y[1]
    q4_0_gemm_b2_nopad<<<grid, block, smem, stream>>>(d_y, d_W, d_X, M, K);
    // Pass 2: x[2], x[3] → y[2], y[3]
    q4_0_gemm_b2_nopad<<<grid, block, smem, stream>>>(d_y + 2*M, d_W, d_X + 2*K, M, K);
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
    int smem_padded = (K + K / 32) * sizeof(float);
    int smem_b2 = 2 * K * sizeof(float);
    int smem_b4 = 4 * K * sizeof(float);

    printf("\n=== %s (%dx%d) ===\n", name, M, K);
    printf("  smem: padded=%d  b2_nopad=%d  b4_nopad=%d\n", smem_padded, smem_b2, smem_b4);

    // Try to set max dynamic shared memory for B=4 kernel
    bool b4_fits = (smem_b4 <= 65536);
    if (b4_fits) {
        cudaError_t err = cudaFuncSetAttribute(q4_0_gemm_b4_nopad,
            cudaFuncAttributeMaxDynamicSharedMemorySize, smem_b4);
        if (err != cudaSuccess) {
            printf("  B=4 smem attribute failed: %s\n", cudaGetErrorString(err));
            b4_fits = false;
        }
    }

    // Warmup
    for (int i = 0; i < 10; i++) {
        q4_0_gemv_padded<<<grid, block, smem_padded>>>(d_y_b1, d_W, d_X, M, K);
        q4_0_gemm_b2_nopad<<<grid, block, smem_b2>>>(d_y_batch, d_W, d_X, M, K);
        if (b4_fits) q4_0_gemm_b4_nopad<<<grid, block, smem_b4>>>(d_y_batch, d_W, d_X, M, K);
        q4_0_gemm_b4_2pass(d_y_batch, d_W, d_X, M, K);
    }
    cudaDeviceSynchronize();
    cudaError_t err = cudaGetLastError();
    if (err != cudaSuccess) printf("  Launch error: %s\n", cudaGetErrorString(err));

    // Correctness: compare batch[0] with B=1 reference
    q4_0_gemv_padded<<<grid, block, smem_padded>>>(d_y_b1, d_W, d_X, M, K);
    cudaDeviceSynchronize();
    cudaMemcpy(h_y_ref, d_y_b1, M * sizeof(float), cudaMemcpyDeviceToHost);

    // Check B=2
    q4_0_gemm_b2_nopad<<<grid, block, smem_b2>>>(d_y_batch, d_W, d_X, M, K);
    cudaDeviceSynchronize();
    cudaMemcpy(h_y_test, d_y_batch, M * sizeof(float), cudaMemcpyDeviceToHost);
    float max_err = 0;
    for (int i = 0; i < M; i++) max_err = fmaxf(max_err, fabsf(h_y_ref[i]-h_y_test[i]));
    printf("  B=2 nopad correctness: max_err=%.6f\n", max_err);

    // Check B=4
    if (b4_fits) {
        q4_0_gemm_b4_nopad<<<grid, block, smem_b4>>>(d_y_batch, d_W, d_X, M, K);
        cudaDeviceSynchronize();
        cudaMemcpy(h_y_test, d_y_batch, M * sizeof(float), cudaMemcpyDeviceToHost);
        max_err = 0;
        for (int i = 0; i < M; i++) max_err = fmaxf(max_err, fabsf(h_y_ref[i]-h_y_test[i]));
        printf("  B=4 nopad correctness: max_err=%.6f\n", max_err);
    }

    // Check 2-pass B=4
    q4_0_gemm_b4_2pass(d_y_batch, d_W, d_X, M, K);
    cudaDeviceSynchronize();
    cudaMemcpy(h_y_test, d_y_batch, M * sizeof(float), cudaMemcpyDeviceToHost);
    max_err = 0;
    for (int i = 0; i < M; i++) max_err = fmaxf(max_err, fabsf(h_y_ref[i]-h_y_test[i]));
    printf("  B=4 2pass correctness: max_err=%.6f\n", max_err);

    // Benchmark
    int n_iters = 200;
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    // B=1 padded (baseline)
    cudaEventRecord(start);
    for (int i = 0; i < n_iters; i++)
        q4_0_gemv_padded<<<grid, block, smem_padded>>>(d_y_b1, d_W, d_X, M, K);
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    float ms_b1; cudaEventElapsedTime(&ms_b1, start, stop); ms_b1 /= n_iters;

    // B=2 unpadded
    cudaEventRecord(start);
    for (int i = 0; i < n_iters; i++)
        q4_0_gemm_b2_nopad<<<grid, block, smem_b2>>>(d_y_batch, d_W, d_X, M, K);
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    float ms_b2; cudaEventElapsedTime(&ms_b2, start, stop); ms_b2 /= n_iters;

    // B=4 unpadded (if fits)
    float ms_b4 = 0;
    if (b4_fits) {
        cudaEventRecord(start);
        for (int i = 0; i < n_iters; i++)
            q4_0_gemm_b4_nopad<<<grid, block, smem_b4>>>(d_y_batch, d_W, d_X, M, K);
        cudaEventRecord(stop);
        cudaEventSynchronize(stop);
        cudaEventElapsedTime(&ms_b4, start, stop); ms_b4 /= n_iters;
    }

    // B=4 via 2-pass B=2
    cudaEventRecord(start);
    for (int i = 0; i < n_iters; i++)
        q4_0_gemm_b4_2pass(d_y_batch, d_W, d_X, M, K);
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    float ms_2pass; cudaEventElapsedTime(&ms_2pass, start, stop); ms_2pass /= n_iters;

    float bw_b1 = (float)W_bytes / (ms_b1 * 1e6f);

    printf("\n  B=1 padded (baseline): %.3f ms  BW=%.1f GB/s  tput=%.0f tok/s\n",
           ms_b1, bw_b1, 1.0f/ms_b1*1000.0f);
    printf("  B=2 nopad:             %.3f ms  BW=%.1f GB/s  tput=%.0f tok/s (%.2fx)\n",
           ms_b2, (float)W_bytes/(ms_b2*1e6f), 2.0f/ms_b2*1000.0f, (2.0f*ms_b1)/ms_b2);
    if (b4_fits)
        printf("  B=4 nopad:             %.3f ms  BW=%.1f GB/s  tput=%.0f tok/s (%.2fx)\n",
               ms_b4, (float)W_bytes/(ms_b4*1e6f), 4.0f/ms_b4*1000.0f, (4.0f*ms_b1)/ms_b4);
    else
        printf("  B=4 nopad:             SKIPPED (smem %d > 64KB)\n", smem_b4);
    printf("  B=4 2pass (2×B=2):     %.3f ms  BW=%.1f GB/s  tput=%.0f tok/s (%.2fx)\n",
           ms_2pass, (float)W_bytes*2/(ms_2pass*1e6f), 4.0f/ms_2pass*1000.0f, (4.0f*ms_b1)/ms_2pass);

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
    printf("GPU: %s  L2=%dKB  smem/block=%dKB  max_smem=%dKB\n",
           prop.name, (int)(prop.l2CacheSize/1024),
           (int)(prop.sharedMemPerBlock/1024),
           (int)(prop.sharedMemPerBlockOptin/1024));

    // K=4096: QKV/O projections, FFN gate/up
    benchmark_config(4096, 4096, "QKV/O (4096x4096)");
    benchmark_config(11008, 4096, "FFN gate/up (11008x4096)");

    // K=11008: FFN down — B=4 won't fit, B=2 might
    benchmark_config(4096, 11008, "FFN down (4096x11008)");

    // Full 7B decode estimate
    printf("\n=== Full 7B Single-Token Decode Estimate ===\n");
    printf("  Per layer: Q,K,V(4096x4096) + O(4096x4096) + gate,up(11008x4096) + down(4096x11008)\n");
    printf("  B=4 works for K=4096 tensors (6 of 7 GEMVs per layer)\n");
    printf("  FFN down (K=11008) must stay at B=1 or B=2\n");

    return 0;
}

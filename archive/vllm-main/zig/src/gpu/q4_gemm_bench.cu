// q4_0_gemm: Batched Q4_0 GEMV (small-batch GEMM)
// Reads weight matrix ONCE, multiplies by B input vectors simultaneously.
// For decode: B=2-4 via speculative decoding or multi-sequence serving.
//
// Theoretical speedup: B× throughput (memory-bound, weights dominate traffic)
//   B=1: 43 TPS baseline (GEMV)
//   B=2: ~86 TPS (same weight reads, 2× compute)
//   B=4: ~172 TPS (same weight reads, 4× compute)
//
// Compile: nvcc -O3 -arch=sm_75 -o q4_gemm_bench q4_gemm_bench.cu && ./q4_gemm_bench

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cmath>
#include <cuda_runtime.h>
#include <cuda_fp16.h>

// ============================================================================
// GEMV baseline (batch=1) — same as our production kernel
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
// GEMM batch=2: Read weights once, compute 2 output vectors
// y0[row] = W[row] . x0,  y1[row] = W[row] . x1
// Shared memory: 2 × (K + K/32) × 4 bytes for padded x0, x1
// ============================================================================
extern "C"
__global__ void q4_0_gemm_b2(float* __restrict__ y0, float* __restrict__ y1,
                              const uint8_t* __restrict__ W,
                              const float* __restrict__ x0, const float* __restrict__ x1,
                              int M, int K) {
    extern __shared__ float smem[];
    int tid = threadIdx.x;
    int n_blocks_per_row = K >> 5;
    int padded_K = K + (K >> 5);  // K + K/32

    float* x0_smem = smem;
    float* x1_smem = smem + padded_K;

    // Load both x vectors into padded shared memory
    for (int idx = tid; idx < K; idx += 256) {
        int padded = idx + (idx >> 5);
        x0_smem[padded] = __ldg(&x0[idx]);
        x1_smem[padded] = __ldg(&x1[idx]);
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
        int x_base = b * 33;

        const uint16_t* data_u16 = reinterpret_cast<const uint16_t*>(block_ptr + 2);
        #pragma unroll
        for (int j = 0; j < 8; j++) {
            uint16_t val = __ldg(&data_u16[j]);
            uint8_t b0 = val & 0xFF;
            uint8_t b1 = val >> 8;

            float w0 = (float)(b0 & 0xF) * scale + neg8s;
            float w1 = (float)(b0 >> 4) * scale + neg8s;
            float w2 = (float)(b1 & 0xF) * scale + neg8s;
            float w3 = (float)(b1 >> 4) * scale + neg8s;

            int xi = x_base + j * 4;
            // Batch 0
            acc0 += w0 * x0_smem[xi];
            acc0 += w1 * x0_smem[xi+1];
            acc0 += w2 * x0_smem[xi+2];
            acc0 += w3 * x0_smem[xi+3];
            // Batch 1
            acc1 += w0 * x1_smem[xi];
            acc1 += w1 * x1_smem[xi+1];
            acc1 += w2 * x1_smem[xi+2];
            acc1 += w3 * x1_smem[xi+3];
        }
    }

    #pragma unroll
    for (int offset = 16; offset >= 1; offset >>= 1) {
        acc0 += __shfl_xor_sync(0xFFFFFFFF, acc0, offset);
        acc1 += __shfl_xor_sync(0xFFFFFFFF, acc1, offset);
    }
    if (tx == 0) { y0[row] = acc0; y1[row] = acc1; }
}

// ============================================================================
// GEMM batch=4: Read weights once, compute 4 output vectors
// ============================================================================
extern "C"
__global__ void q4_0_gemm_b4(float* __restrict__ y0, float* __restrict__ y1,
                              float* __restrict__ y2, float* __restrict__ y3,
                              const uint8_t* __restrict__ W,
                              const float* __restrict__ x0, const float* __restrict__ x1,
                              const float* __restrict__ x2, const float* __restrict__ x3,
                              int M, int K) {
    extern __shared__ float smem[];
    int tid = threadIdx.x;
    int n_blocks_per_row = K >> 5;
    int padded_K = K + (K >> 5);

    float* xs[4] = { smem, smem + padded_K, smem + 2*padded_K, smem + 3*padded_K };
    const float* xg[4] = { x0, x1, x2, x3 };

    for (int idx = tid; idx < K; idx += 256) {
        int padded = idx + (idx >> 5);
        xs[0][padded] = __ldg(&xg[0][idx]);
        xs[1][padded] = __ldg(&xg[1][idx]);
        xs[2][padded] = __ldg(&xg[2][idx]);
        xs[3][padded] = __ldg(&xg[3][idx]);
    }
    __syncthreads();

    int tx = tid & 31;
    int ty = tid >> 5;
    int row = blockIdx.x * 8 + ty;
    if (row >= M) return;

    const uint8_t* W_row = W + (long long)row * n_blocks_per_row * 18;
    float acc[4] = {0,0,0,0};

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

            float w0 = (float)(b0 & 0xF) * scale + neg8s;
            float w1 = (float)(b0 >> 4) * scale + neg8s;
            float w2 = (float)(b1 & 0xF) * scale + neg8s;
            float w3 = (float)(b1 >> 4) * scale + neg8s;

            int xi = x_base + j * 4;
            #pragma unroll
            for (int bi = 0; bi < 4; bi++) {
                acc[bi] += w0 * xs[bi][xi];
                acc[bi] += w1 * xs[bi][xi+1];
                acc[bi] += w2 * xs[bi][xi+2];
                acc[bi] += w3 * xs[bi][xi+3];
            }
        }
    }

    float* yp[4] = { y0, y1, y2, y3 };
    #pragma unroll
    for (int offset = 16; offset >= 1; offset >>= 1) {
        #pragma unroll
        for (int bi = 0; bi < 4; bi++)
            acc[bi] += __shfl_xor_sync(0xFFFFFFFF, acc[bi], offset);
    }
    if (tx == 0) {
        #pragma unroll
        for (int bi = 0; bi < 4; bi++) yp[bi][row] = acc[bi];
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

int main() {
    // Test with both 4096×4096 and 11008×4096
    struct { int M; int K; const char* name; } configs[] = {
        {4096, 4096, "QKV/O (4096x4096)"},
        {11008, 4096, "FFN (11008x4096)"},
    };

    for (auto& cfg : configs) {
        int M = cfg.M, K = cfg.K;
        int n_blocks = K / 32;
        size_t W_bytes = (size_t)M * n_blocks * 18;

        float *h_x0 = (float*)malloc(K * sizeof(float));
        float *h_x1 = (float*)malloc(K * sizeof(float));
        uint8_t *h_W = (uint8_t*)malloc(W_bytes);

        srand(42);
        for (int i = 0; i < K; i++) {
            h_x0[i] = (float)(rand() % 200 - 100) / 100.0f;
            h_x1[i] = (float)(rand() % 200 - 100) / 100.0f;
        }
        for (size_t i = 0; i < W_bytes; i++) h_W[i] = rand() & 0xFF;
        for (int r = 0; r < M; r++) {
            for (int b = 0; b < n_blocks; b++) {
                float s = 0.01f * ((rand() % 100) + 1);
                uint16_t h = f32_to_f16_bits(s);
                memcpy(&h_W[(size_t)r * n_blocks * 18 + b * 18], &h, 2);
            }
        }

        float *d_y0, *d_y1, *d_y2, *d_y3;
        float *d_x0, *d_x1, *d_x2, *d_x3;
        uint8_t *d_W;
        cudaMalloc(&d_y0, M * sizeof(float));
        cudaMalloc(&d_y1, M * sizeof(float));
        cudaMalloc(&d_y2, M * sizeof(float));
        cudaMalloc(&d_y3, M * sizeof(float));
        cudaMalloc(&d_x0, K * sizeof(float));
        cudaMalloc(&d_x1, K * sizeof(float));
        cudaMalloc(&d_x2, K * sizeof(float));
        cudaMalloc(&d_x3, K * sizeof(float));
        cudaMalloc(&d_W, W_bytes);
        cudaMemcpy(d_W, h_W, W_bytes, cudaMemcpyHostToDevice);
        cudaMemcpy(d_x0, h_x0, K*4, cudaMemcpyHostToDevice);
        cudaMemcpy(d_x1, h_x1, K*4, cudaMemcpyHostToDevice);
        cudaMemcpy(d_x2, h_x0, K*4, cudaMemcpyHostToDevice);  // reuse
        cudaMemcpy(d_x3, h_x1, K*4, cudaMemcpyHostToDevice);

        dim3 grid((M + 7) / 8), block(256);
        int padded_K = K + K/32;
        int smem_b1 = padded_K * 4;
        int smem_b2 = padded_K * 4 * 2;
        int smem_b4 = padded_K * 4 * 4;

        // Check shared memory limits
        int max_smem;
        cudaDeviceGetAttribute(&max_smem, cudaDevAttrMaxSharedMemoryPerBlock, 0);
        printf("\n=== %s (max_smem=%d) ===\n", cfg.name, max_smem);
        printf("  smem needed: b1=%d  b2=%d  b4=%d bytes\n", smem_b1, smem_b2, smem_b4);

        if (smem_b4 > max_smem) {
            // Try setting max dynamic shared memory
            cudaFuncSetAttribute(q4_0_gemm_b4,
                cudaFuncAttributeMaxDynamicSharedMemorySize, smem_b4);
        }

        // Warmup
        for (int i = 0; i < 5; i++) {
            q4_0_gemv<<<grid, block, smem_b1>>>(d_y0, d_W, d_x0, M, K);
            q4_0_gemm_b2<<<grid, block, smem_b2>>>(d_y0, d_y1, d_W, d_x0, d_x1, M, K);
            if (smem_b4 <= 65536)
                q4_0_gemm_b4<<<grid, block, smem_b4>>>(d_y0, d_y1, d_y2, d_y3, d_W, d_x0, d_x1, d_x2, d_x3, M, K);
        }
        cudaDeviceSynchronize();
        cudaError_t err = cudaGetLastError();
        if (err != cudaSuccess) printf("  Launch error: %s\n", cudaGetErrorString(err));

        // Benchmark
        int n_iters = 200;
        cudaEvent_t start, stop;
        cudaEventCreate(&start);
        cudaEventCreate(&stop);

        // B=1 (GEMV baseline)
        cudaEventRecord(start);
        for (int i = 0; i < n_iters; i++)
            q4_0_gemv<<<grid, block, smem_b1>>>(d_y0, d_W, d_x0, M, K);
        cudaEventRecord(stop);
        cudaEventSynchronize(stop);
        float ms_b1; cudaEventElapsedTime(&ms_b1, start, stop); ms_b1 /= n_iters;

        // B=2
        cudaEventRecord(start);
        for (int i = 0; i < n_iters; i++)
            q4_0_gemm_b2<<<grid, block, smem_b2>>>(d_y0, d_y1, d_W, d_x0, d_x1, M, K);
        cudaEventRecord(stop);
        cudaEventSynchronize(stop);
        float ms_b2; cudaEventElapsedTime(&ms_b2, start, stop); ms_b2 /= n_iters;

        // B=4
        float ms_b4 = 0;
        if (smem_b4 <= 65536) {
            cudaEventRecord(start);
            for (int i = 0; i < n_iters; i++)
                q4_0_gemm_b4<<<grid, block, smem_b4>>>(d_y0, d_y1, d_y2, d_y3, d_W, d_x0, d_x1, d_x2, d_x3, M, K);
            cudaEventRecord(stop);
            cudaEventSynchronize(stop);
            cudaEventElapsedTime(&ms_b4, start, stop); ms_b4 /= n_iters;
        }

        float bw_b1 = (float)W_bytes / (ms_b1 * 1e6f);
        float bw_b2 = (float)W_bytes / (ms_b2 * 1e6f);  // same weight data, 2 outputs

        printf("  B=1 GEMV:  %.3f ms  BW=%.1f GB/s  throughput=%.0f tok/s equiv\n",
               ms_b1, bw_b1, 1.0f/ms_b1*1000.0f);
        printf("  B=2 GEMM:  %.3f ms  BW=%.1f GB/s  throughput=%.0f tok/s equiv (%.2fx)\n",
               ms_b2, bw_b2, 2.0f/ms_b2*1000.0f, (2.0f*ms_b1)/(ms_b2));
        if (ms_b4 > 0) {
            float bw_b4 = (float)W_bytes / (ms_b4 * 1e6f);
            printf("  B=4 GEMM:  %.3f ms  BW=%.1f GB/s  throughput=%.0f tok/s equiv (%.2fx)\n",
                   ms_b4, bw_b4, 4.0f/ms_b4*1000.0f, (4.0f*ms_b1)/(ms_b4));
        } else {
            printf("  B=4 GEMM:  SKIPPED (smem %d > 64KB)\n", smem_b4);
        }

        cudaEventDestroy(start);
        cudaEventDestroy(stop);
        cudaFree(d_y0); cudaFree(d_y1); cudaFree(d_y2); cudaFree(d_y3);
        cudaFree(d_x0); cudaFree(d_x1); cudaFree(d_x2); cudaFree(d_x3);
        cudaFree(d_W);
        free(h_x0); free(h_x1); free(h_W);
    }

    return 0;
}

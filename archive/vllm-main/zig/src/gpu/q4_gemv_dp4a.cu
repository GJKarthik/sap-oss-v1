// q4_0_gemv with dp4a INT8 acceleration
// Compile: nvcc -O3 -arch=sm_75 -o q4_gemv_dp4a q4_gemv_dp4a.cu && ./q4_gemv_dp4a
//
// Key idea: dp4a processes 4 INT8 multiply-accumulates in 1 instruction
// vs 4 separate fma.f32. This reduces instruction pressure, allowing
// the memory pipeline to issue more requests and improve BW utilization.
//
// Algorithm:
//   1. Cooperative load x[] into shared memory as FP32
//   2. Quantize x[] to INT8 in shared memory (per-block-of-32 scale)
//   3. For each Q4 block: extract nibbles to signed INT8 (-8..+7),
//      use dp4a with INT8 x values, accumulate in INT32
//   4. Final: float_result = int32_acc * q4_scale * x_scale
//   5. Warp shuffle reduction

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cmath>
#include <cuda_runtime.h>
#include <cuda_fp16.h>

// dp4a intrinsic: computes dot product of 4 signed int8 pairs, accumulates to int32
// d = __dp4a(a, b, c) = a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w + c
// where a,b are packed 4×int8 in uint32, c/d are int32

extern "C"
__global__ void q4_0_gemv_dp4a(float* __restrict__ y,
                                const uint8_t* __restrict__ W,
                                const float* __restrict__ x,
                                int M, int K) {
    // Shared memory layout:
    // [0 .. K-1+K/32-1]: padded FP32 x[] (for initial load, then overwritten)
    // After quantization:
    // [0 .. K/4-1]: packed INT8 x[] (4 values per u32)
    // [K/4 .. K/4 + K/32-1]: per-block x_scale (float)
    extern __shared__ float smem_f[];

    int tid = threadIdx.x;
    int n_blocks_per_row = K >> 5;  // K / 32

    // Layout pointers
    // Phase 1: padded FP32 x[] at smem_f[idx + idx/32]
    // Phase 2: packed INT8 x at smem_u32[0..K/4-1], scales at smem_f[K/4..K/4+K/32-1]
    uint32_t* smem_u32 = (uint32_t*)smem_f;

    // --- Phase 0: Load x[] into padded shared memory as FP32 ---
    for (int idx = tid; idx < K; idx += 256) {
        int padded = idx + (idx >> 5);  // bank-conflict-free padding
        smem_f[padded] = __ldg(&x[idx]);
    }
    __syncthreads();

    // --- Phase 0b: Quantize x[] to INT8 in shared memory ---
    // Race condition fix: packed INT8 output (smem_u32[g*8..]) overlaps with
    // padded FP32 input (smem_f[g'*33..]). Different threads process different
    // groups, so thread A's INT8 writes can corrupt thread B's FP32 reads.
    // Fix: two-pass — read ALL FP32 into registers first, sync, then write.
    //
    // Layout after phase 0b:
    //   smem_u32[0 .. K/4-1]: packed int8x4 x values
    //   smem_f[K/4 .. K/4 + n_blocks_per_row-1]: per-group x_scale (float)
    float* x_scales = &smem_f[K / 4];  // scales stored after packed int8 data

    // Max 2 groups per thread (K=11008 → 344 groups / 256 threads ≈ 1.34)
    int8_t local_q0[32], local_q1[32];
    float local_scale0 = 0.0f, local_scale1 = 0.0f;
    int g0 = tid, g1 = tid + 256;

    // Pass 1: Read all FP32 data into registers (no smem writes yet)
    if (g0 < n_blocks_per_row) {
        float absmax = 0.0f;
        int base_padded = g0 * 33;
        #pragma unroll
        for (int i = 0; i < 32; i++)
            absmax = fmaxf(absmax, fabsf(smem_f[base_padded + i]));
        local_scale0 = absmax / 127.0f;
        float inv_scale = (absmax > 0.0f) ? 127.0f / absmax : 0.0f;
        #pragma unroll
        for (int i = 0; i < 32; i++)
            local_q0[i] = (int8_t)__float2int_rn(smem_f[base_padded + i] * inv_scale);
    }
    if (g1 < n_blocks_per_row) {
        float absmax = 0.0f;
        int base_padded = g1 * 33;
        #pragma unroll
        for (int i = 0; i < 32; i++)
            absmax = fmaxf(absmax, fabsf(smem_f[base_padded + i]));
        local_scale1 = absmax / 127.0f;
        float inv_scale = (absmax > 0.0f) ? 127.0f / absmax : 0.0f;
        #pragma unroll
        for (int i = 0; i < 32; i++)
            local_q1[i] = (int8_t)__float2int_rn(smem_f[base_padded + i] * inv_scale);
    }
    __syncthreads();  // all FP32 reads done; safe to overwrite smem

    // Pass 2: Write packed INT8 + scales into shared memory
    if (g0 < n_blocks_per_row) {
        x_scales[g0] = local_scale0;
        #pragma unroll
        for (int j = 0; j < 8; j++) {
            uint32_t packed = ((uint32_t)(uint8_t)local_q0[j*4+0])
                            | ((uint32_t)(uint8_t)local_q0[j*4+1] << 8)
                            | ((uint32_t)(uint8_t)local_q0[j*4+2] << 16)
                            | ((uint32_t)(uint8_t)local_q0[j*4+3] << 24);
            smem_u32[g0 * 8 + j] = packed;
        }
    }
    if (g1 < n_blocks_per_row) {
        x_scales[g1] = local_scale1;
        #pragma unroll
        for (int j = 0; j < 8; j++) {
            uint32_t packed = ((uint32_t)(uint8_t)local_q1[j*4+0])
                            | ((uint32_t)(uint8_t)local_q1[j*4+1] << 8)
                            | ((uint32_t)(uint8_t)local_q1[j*4+2] << 16)
                            | ((uint32_t)(uint8_t)local_q1[j*4+3] << 24);
            smem_u32[g1 * 8 + j] = packed;
        }
    }
    __syncthreads();

    // --- Thread indexing ---
    int tx = tid & 31;       // lane within warp
    int ty = tid >> 5;        // warp index (0..7)
    int row = blockIdx.x * 8 + ty;
    if (row >= M) return;

    const uint8_t* W_row = W + (long long)row * n_blocks_per_row * 18;

    // --- Phase 1: dp4a dot product ---
    float acc_f32 = 0.0f;     // FP32 accumulator for scaled results

    for (int b = tx; b < n_blocks_per_row; b += 32) {
        const uint8_t* block_ptr = W_row + b * 18;

        // Load Q4 scale (f16 at offset 0)
        float q4_scale = __half2float(*reinterpret_cast<const __half*>(block_ptr));

        // Load x_scale for this group
        float xs = x_scales[b];

        // Combined scale
        float combined_scale = q4_scale * xs;

        // Load 16 data bytes as 8 x u16, then combine into 4 x u32
        // (block_ptr+2 is only 2-byte aligned, can't do u32 loads directly)
        const uint16_t* data_u16 = reinterpret_cast<const uint16_t*>(block_ptr + 2);
        uint32_t d0 = (uint32_t)__ldg(&data_u16[0]) | ((uint32_t)__ldg(&data_u16[1]) << 16);
        uint32_t d1 = (uint32_t)__ldg(&data_u16[2]) | ((uint32_t)__ldg(&data_u16[3]) << 16);
        uint32_t d2 = (uint32_t)__ldg(&data_u16[4]) | ((uint32_t)__ldg(&data_u16[5]) << 16);
        uint32_t d3 = (uint32_t)__ldg(&data_u16[6]) | ((uint32_t)__ldg(&data_u16[7]) << 16);

        // For each u32 of weight data (4 bytes = 8 nibbles),
        // extract nibbles, subtract 8, pack as signed int8x4,
        // then dp4a with corresponding packed x_int8x4.
        //
        // Weight byte layout: [nib1|nib0] per byte
        // We need to split each byte into 2 nibbles and subtract 8.

        // Process d0 (8 nibbles = 8 weight values, indices 0-7)
        // Nibble extraction + subtract 8:
        //   low nibbles of each byte: d0 & 0x0F0F0F0F
        //   high nibbles: (d0 >> 4) & 0x0F0F0F0F
        //   Subtract 8 from each byte: add 0xF8F8F8F8 (two's complement of 8)

        // Pack nibbles in sequential order for dp4a:
        // For bytes b0, b1 → nibbles n0,n1,n2,n3 → packed as {n0,n1,n2,n3}
        // n0 = b0 & 0xF, n1 = b0 >> 4, n2 = b1 & 0xF, n3 = b1 >> 4
        // packed = n0 | (n1 << 8) | (n2 << 16) | (n3 << 24)

        // Helper: unpack a u32 of 4 packed bytes into 8 nibbles repacked sequentially
        // Input:  u32 = [byte3|byte2|byte1|byte0]
        // Output: two u32s, each with 4 sequential nibbles - 8
        auto unpack_nibs = [](uint32_t d, uint32_t &seq0, uint32_t &seq1) {
            // Extract individual bytes
            uint32_t b0 = d & 0xFF;
            uint32_t b1 = (d >> 8) & 0xFF;
            uint32_t b2 = (d >> 16) & 0xFF;
            uint32_t b3 = (d >> 24) & 0xFF;
            // Sequential nibble packing for values 0-3 (from bytes 0,1):
            // n0=b0&0xF, n1=b0>>4, n2=b1&0xF, n3=b1>>4
            uint32_t n0 = (b0 & 0xF) - 8;
            uint32_t n1 = (b0 >> 4) - 8;
            uint32_t n2 = (b1 & 0xF) - 8;
            uint32_t n3 = (b1 >> 4) - 8;
            seq0 = (n0 & 0xFF) | ((n1 & 0xFF) << 8) | ((n2 & 0xFF) << 16) | ((n3 & 0xFF) << 24);
            // Values 4-7 (from bytes 2,3):
            uint32_t n4 = (b2 & 0xF) - 8;
            uint32_t n5 = (b2 >> 4) - 8;
            uint32_t n6 = (b3 & 0xF) - 8;
            uint32_t n7 = (b3 >> 4) - 8;
            seq1 = (n4 & 0xFF) | ((n5 & 0xFF) << 8) | ((n6 & 0xFF) << 16) | ((n7 & 0xFF) << 24);
        };

        uint32_t w01, w23;  // packed signed int8 weights, sequential order
        int block_acc = 0;

        // d0: weight bytes 0-3 → values 0-7
        unpack_nibs(d0, w01, w23);
        block_acc = __dp4a((int)w01, (int)smem_u32[b*8+0], block_acc);  // values 0-3
        block_acc = __dp4a((int)w23, (int)smem_u32[b*8+1], block_acc);  // values 4-7

        // d1: weight bytes 4-7 → values 8-15
        unpack_nibs(d1, w01, w23);
        block_acc = __dp4a((int)w01, (int)smem_u32[b*8+2], block_acc);  // values 8-11
        block_acc = __dp4a((int)w23, (int)smem_u32[b*8+3], block_acc);  // values 12-15

        // d2: weight bytes 8-11 → values 16-23
        unpack_nibs(d2, w01, w23);
        block_acc = __dp4a((int)w01, (int)smem_u32[b*8+4], block_acc);  // values 16-19
        block_acc = __dp4a((int)w23, (int)smem_u32[b*8+5], block_acc);  // values 20-23

        // d3: weight bytes 12-15 → values 24-31
        unpack_nibs(d3, w01, w23);
        block_acc = __dp4a((int)w01, (int)smem_u32[b*8+6], block_acc);  // values 24-27
        block_acc = __dp4a((int)w23, (int)smem_u32[b*8+7], block_acc);  // values 28-31

        // Scale: block_acc is int32 sum of (nibble-8) * x_int8
        // Real result = block_acc * q4_scale * x_scale
        acc_f32 += (float)block_acc * combined_scale;
    }

    // --- Phase 2: Warp shuffle butterfly reduction ---
    #pragma unroll
    for (int offset = 16; offset >= 1; offset >>= 1) {
        acc_f32 += __shfl_xor_sync(0xFFFFFFFF, acc_f32, offset);
    }
    if (tx == 0) y[row] = acc_f32;
}

// Baseline FP32 kernel for comparison (same as before)
extern "C"
__global__ void q4_0_gemv_fp32(float* __restrict__ y,
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
    for (int offset = 16; offset >= 1; offset >>= 1) {
        acc += __shfl_xor_sync(0xFFFFFFFF, acc, offset);
    }
    if (tx == 0) y[row] = acc;
}


int main() {
    int M = 4096, K = 4096;
    int n_blocks = K / 32;
    size_t W_bytes = (size_t)M * n_blocks * 18;

    // Allocate host
    float* h_y = (float*)malloc(M * sizeof(float));
    float* h_y2 = (float*)malloc(M * sizeof(float));
    uint8_t* h_W = (uint8_t*)malloc(W_bytes);
    float* h_x = (float*)malloc(K * sizeof(float));

    // Initialize with deterministic values
    srand(42);
    for (int i = 0; i < K; i++) h_x[i] = (float)(rand() % 200 - 100) / 100.0f;
    for (size_t i = 0; i < W_bytes; i++) h_W[i] = rand() & 0xFF;
    // Set realistic f16 scales (every 18 bytes) using bit pattern for f16
    for (int r = 0; r < M; r++) {
        for (int b = 0; b < n_blocks; b++) {
            // f16 scale ~0.01-1.0: use f16 bit pattern directly
            // f16: sign(1) exp(5) mantissa(10), 0x2C00 ≈ 0.0625
            float s = 0.01f * ((rand() % 100) + 1);
            uint16_t h;
            // Simple f32->f16 conversion
            uint32_t f = *(uint32_t*)&s;
            uint32_t sign = (f >> 16) & 0x8000;
            int exp = ((f >> 23) & 0xFF) - 127 + 15;
            uint32_t mant = (f >> 13) & 0x3FF;
            if (exp <= 0) h = (uint16_t)sign;
            else if (exp >= 31) h = (uint16_t)(sign | 0x7C00);
            else h = (uint16_t)(sign | (exp << 10) | mant);
            memcpy(&h_W[(size_t)r * n_blocks * 18 + b * 18], &h, 2);
        }
    }

    // Allocate device
    float *d_y, *d_y2, *d_x;
    uint8_t *d_W;
    cudaMalloc(&d_y, M * sizeof(float));
    cudaMalloc(&d_y2, M * sizeof(float));
    cudaMalloc(&d_x, K * sizeof(float));
    cudaMalloc(&d_W, W_bytes);
    cudaMemcpy(d_W, h_W, W_bytes, cudaMemcpyHostToDevice);
    cudaMemcpy(d_x, h_x, K * sizeof(float), cudaMemcpyHostToDevice);

    dim3 grid((M + 7) / 8);
    dim3 block(256);
    int smem_fp32 = (K + K / 32) * sizeof(float);  // padded FP32 x[]
    // dp4a needs: max(padded FP32 for load, packed INT8 + scales for compute)
    // padded FP32: (K + K/32) * 4 bytes
    // packed INT8: K bytes + n_blocks * 4 bytes for scales
    // padded FP32 is always larger, so use that
    int smem_dp4a = smem_fp32;

    printf("Grid: %d blocks, Block: %d threads, smem_fp32: %d bytes\n", grid.x, block.x, smem_fp32);

    // Warmup + error check
    q4_0_gemv_fp32<<<grid, block, smem_fp32>>>(d_y, d_W, d_x, M, K);
    cudaError_t err = cudaGetLastError();
    if (err != cudaSuccess) printf("FP32 launch error: %s\n", cudaGetErrorString(err));
    cudaDeviceSynchronize();
    err = cudaGetLastError();
    if (err != cudaSuccess) printf("FP32 sync error: %s\n", cudaGetErrorString(err));

    q4_0_gemv_dp4a<<<grid, block, smem_dp4a>>>(d_y2, d_W, d_x, M, K);
    err = cudaGetLastError();
    if (err != cudaSuccess) printf("dp4a launch error: %s\n", cudaGetErrorString(err));
    cudaDeviceSynchronize();
    err = cudaGetLastError();
    if (err != cudaSuccess) printf("dp4a sync error: %s\n", cudaGetErrorString(err));

    for (int i = 0; i < 9; i++) {
        q4_0_gemv_fp32<<<grid, block, smem_fp32>>>(d_y, d_W, d_x, M, K);
        q4_0_gemv_dp4a<<<grid, block, smem_dp4a>>>(d_y2, d_W, d_x, M, K);
    }
    cudaDeviceSynchronize();

    // Correctness check
    cudaMemcpy(h_y, d_y, M * sizeof(float), cudaMemcpyDeviceToHost);
    cudaMemcpy(h_y2, d_y2, M * sizeof(float), cudaMemcpyDeviceToHost);

    float max_err = 0.0f, max_rel = 0.0f;
    for (int i = 0; i < M; i++) {
        float err = fabsf(h_y[i] - h_y2[i]);
        float rel = (fabsf(h_y[i]) > 1e-6f) ? err / fabsf(h_y[i]) : err;
        if (err > max_err) max_err = err;
        if (rel > max_rel) max_rel = rel;
    }
    printf("Correctness: max_abs_err=%.6f  max_rel_err=%.4f%%\n", max_err, max_rel * 100.0f);
    printf("  y_fp32[0..3] = %.4f %.4f %.4f %.4f\n", h_y[0], h_y[1], h_y[2], h_y[3]);
    printf("  y_dp4a[0..3] = %.4f %.4f %.4f %.4f\n", h_y2[0], h_y2[1], h_y2[2], h_y2[3]);

    // Benchmark
    int n_iters = 200;
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    // FP32 baseline
    cudaEventRecord(start);
    for (int i = 0; i < n_iters; i++) {
        q4_0_gemv_fp32<<<grid, block, smem_fp32>>>(d_y, d_W, d_x, M, K);
    }
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    float ms_fp32;
    cudaEventElapsedTime(&ms_fp32, start, stop);
    ms_fp32 /= n_iters;

    // dp4a version
    cudaEventRecord(start);
    for (int i = 0; i < n_iters; i++) {
        q4_0_gemv_dp4a<<<grid, block, smem_dp4a>>>(d_y2, d_W, d_x, M, K);
    }
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    float ms_dp4a;
    cudaEventElapsedTime(&ms_dp4a, start, stop);
    ms_dp4a /= n_iters;

    float bw_fp32 = (float)W_bytes / (ms_fp32 * 1e6f);
    float bw_dp4a = (float)W_bytes / (ms_dp4a * 1e6f);

    printf("\nBenchmark (%dx%d, %d iters):\n", M, K, n_iters);
    printf("  FP32 baseline: %.3f ms  BW=%.1f GB/s\n", ms_fp32, bw_fp32);
    printf("  dp4a INT8:     %.3f ms  BW=%.1f GB/s\n", ms_dp4a, bw_dp4a);
    printf("  Speedup: %.2fx\n", ms_fp32 / ms_dp4a);

    // Also test 11008x4096 (FFN dimensions)
    int M2 = 11008, K2 = 4096;
    int nb2 = K2 / 32;
    size_t W2_bytes = (size_t)M2 * nb2 * 18;
    float *d_y3, *d_y4;
    uint8_t *d_W2;
    cudaMalloc(&d_y3, M2 * sizeof(float));
    cudaMalloc(&d_y4, M2 * sizeof(float));
    cudaMalloc(&d_W2, W2_bytes);
    // Just reuse random data
    cudaMemset(d_W2, 0x42, W2_bytes);

    dim3 grid2((M2 + 7) / 8);
    for (int i = 0; i < 10; i++) {
        q4_0_gemv_fp32<<<grid2, block, smem_fp32>>>(d_y3, d_W2, d_x, M2, K2);
        q4_0_gemv_dp4a<<<grid2, block, smem_dp4a>>>(d_y4, d_W2, d_x, M2, K2);
    }
    cudaDeviceSynchronize();

    cudaEventRecord(start);
    for (int i = 0; i < n_iters; i++) {
        q4_0_gemv_fp32<<<grid2, block, smem_fp32>>>(d_y3, d_W2, d_x, M2, K2);
    }
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    float ms2_fp32;
    cudaEventElapsedTime(&ms2_fp32, start, stop);
    ms2_fp32 /= n_iters;

    cudaEventRecord(start);
    for (int i = 0; i < n_iters; i++) {
        q4_0_gemv_dp4a<<<grid2, block, smem_dp4a>>>(d_y4, d_W2, d_x, M2, K2);
    }
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    float ms2_dp4a;
    cudaEventElapsedTime(&ms2_dp4a, start, stop);
    ms2_dp4a /= n_iters;

    float bw2_fp32 = (float)W2_bytes / (ms2_fp32 * 1e6f);
    float bw2_dp4a = (float)W2_bytes / (ms2_dp4a * 1e6f);

    printf("\nBenchmark (%dx%d, %d iters):\n", M2, K2, n_iters);
    printf("  FP32 baseline: %.3f ms  BW=%.1f GB/s\n", ms2_fp32, bw2_fp32);
    printf("  dp4a INT8:     %.3f ms  BW=%.1f GB/s\n", ms2_dp4a, bw2_dp4a);
    printf("  Speedup: %.2fx\n", ms2_fp32 / ms2_dp4a);

    cudaFree(d_y); cudaFree(d_y2); cudaFree(d_x); cudaFree(d_W);
    cudaFree(d_y3); cudaFree(d_y4); cudaFree(d_W2);
    free(h_y); free(h_y2); free(h_W); free(h_x);
    return 0;
}

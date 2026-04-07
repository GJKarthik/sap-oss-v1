// q4_1_gemv standalone kernel -- compiled by nvcc, PTX extracted and integrated
// Q4_1 block format: f16 delta (2B) + f16 min (2B) + 16 data bytes (32 nibbles) = 20 bytes
// Dequant: w = nibble * delta + min
// Compile: nvcc -O3 -arch=sm_75 -ptx q4_1_gemv_kernel.cu
#include <cstdint>
#include <cuda_runtime.h>
#include <cuda_fp16.h>

extern "C"
__global__ void q4_1_gemv(float* __restrict__ y,
                          const uint8_t* __restrict__ W,
                          const float* __restrict__ x,
                          int M, int K) {
    extern __shared__ float x_smem[];
    int tid = threadIdx.x;
    int n_blocks_per_row = K >> 5;

    // Phase 0: Cooperative load of x[] into padded shared memory
    for (int idx = tid; idx < K; idx += 256) {
        int padded = idx + (idx >> 5);
        x_smem[padded] = __ldg(&x[idx]);
    }
    __syncthreads();

    // Thread indexing: 8 warps x 32 lanes
    int tx = tid & 31;
    int ty = tid >> 5;
    int row = blockIdx.x * 8 + ty;
    if (row >= M) return;

    // Row pointer (20 bytes per Q4_1 block)
    const uint8_t* W_row = W + (long long)row * n_blocks_per_row * 20;

    // Phase 1: Each lane processes blocks tx, tx+32, tx+64, ...
    float acc = 0.0f;
    for (int b = tx; b < n_blocks_per_row; b += 32) {
        const uint8_t* block_ptr = W_row + b * 20;

        // Delta (f16 at offset 0) and min (f16 at offset 2)
        float delta = __half2float(*reinterpret_cast<const __half*>(block_ptr));
        float min_val = __half2float(*reinterpret_cast<const __half*>(block_ptr + 2));

        // Padded x base
        int x_base = b * 33;

        // Process 16 data bytes (at offset 4) as 8 x u16 loads
        const uint16_t* data_u16 = reinterpret_cast<const uint16_t*>(block_ptr + 4);
        #pragma unroll
        for (int j = 0; j < 8; j++) {
            uint16_t val = __ldg(&data_u16[j]);
            uint8_t b0 = val & 0xFF;
            uint8_t b1 = val >> 8;

            float w0 = (float)(b0 & 0xF) * delta + min_val;
            float w1 = (float)(b0 >> 4) * delta + min_val;
            float w2 = (float)(b1 & 0xF) * delta + min_val;
            float w3 = (float)(b1 >> 4) * delta + min_val;

            acc += w0 * x_smem[x_base + j * 4];
            acc += w1 * x_smem[x_base + j * 4 + 1];
            acc += w2 * x_smem[x_base + j * 4 + 2];
            acc += w3 * x_smem[x_base + j * 4 + 3];
        }
    }

    // Phase 2: Warp shuffle butterfly reduction
    #pragma unroll
    for (int offset = 16; offset >= 1; offset >>= 1) {
        acc += __shfl_xor_sync(0xFFFFFFFF, acc, offset);
    }
    if (tx == 0) y[row] = acc;
}


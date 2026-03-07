// q4_0_gemv CUDA C kernel -- compiled by nvcc for comparison with hand-written PTX
// Usage: nvcc -O3 -arch=sm_75 -o q4_gemv_bench q4_gemv_bench.cu && ./q4_gemv_bench
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cuda_runtime.h>
#include <cuda_fp16.h>

// Q4_0 block: 2 bytes scale (f16) + 16 bytes data (32 nibbles) = 18 bytes
struct q4_0_block {
    __half scale;
    uint8_t data[16];
};

// ============================================================================
// Kernel: q4_0_gemv -- matches hand-written PTX architecture
// 256 threads/block, 8 warps, 1 warp per row, shared memory x[] with padding
// ============================================================================
__global__ void q4_0_gemv(float* __restrict__ y,
                          const uint8_t* __restrict__ W,
                          const float* __restrict__ x,
                          int M, int K) {
    // Padded shared memory: x[k] at index (k + k/32) to avoid bank conflicts
    extern __shared__ float x_smem[];

    int tid = threadIdx.x;
    int n_blocks_per_row = K / 32;

    // Phase 0: Cooperative load of x[] into padded shared memory
    for (int idx = tid; idx < K; idx += 256) {
        int padded = idx + (idx >> 5);  // idx + idx/32
        x_smem[padded] = x[idx];
    }
    __syncthreads();

    // Thread indexing: 8 warps x 32 lanes
    int tx = tid & 31;          // lane
    int ty = tid >> 5;          // warp index (row within block)
    int row = blockIdx.x * 8 + ty;
    if (row >= M) return;

    // Row pointer into weight matrix
    int row_stride = n_blocks_per_row * 18;
    const uint8_t* W_row = W + row * row_stride;

    // Phase 1: Each lane processes blocks tx, tx+32, tx+64, ...
    float acc = 0.0f;
    for (int b = tx; b < n_blocks_per_row; b += 32) {
        const uint8_t* block_ptr = W_row + b * 18;

        // Load scale (f16 at offset 0)
        __half h_scale = *reinterpret_cast<const __half*>(block_ptr);
        float scale = __half2float(h_scale);
        float neg8_scale = scale * (-8.0f);

        // Padded x base for this block
        int x_base = b * 33;  // b * 32 + b (padded)

        // Process 16 data bytes = 32 nibbles
        #pragma unroll
        for (int j = 0; j < 16; j++) {
            uint8_t byte = block_ptr[2 + j];
            int lo = byte & 0xF;
            int hi = byte >> 4;
            float w_lo = (float)lo * scale + neg8_scale;
            float w_hi = (float)hi * scale + neg8_scale;
            acc += w_lo * x_smem[x_base + j * 2];
            acc += w_hi * x_smem[x_base + j * 2 + 1];
        }
    }

    // Phase 2: Warp shuffle butterfly reduction
    #pragma unroll
    for (int offset = 16; offset >= 1; offset >>= 1) {
        acc += __shfl_xor_sync(0xFFFFFFFF, acc, offset);
    }

    // Lane 0 writes result
    if (tx == 0) {
        y[row] = acc;
    }
}

// ============================================================================
// Kernel V2: Use uint16 loads (matches PTX u16 approach)
// ============================================================================
__global__ void q4_0_gemv_v2(float* __restrict__ y,
                             const uint8_t* __restrict__ W,
                             const float* __restrict__ x,
                             int M, int K) {
    extern __shared__ float x_smem[];
    int tid = threadIdx.x;
    int n_blocks_per_row = K / 32;

    for (int idx = tid; idx < K; idx += 256) {
        int padded = idx + (idx >> 5);
        x_smem[padded] = x[idx];
    }
    __syncthreads();

    int tx = tid & 31;
    int ty = tid >> 5;
    int row = blockIdx.x * 8 + ty;
    if (row >= M) return;

    int row_stride = n_blocks_per_row * 18;
    const uint8_t* W_row = W + row * row_stride;

    float acc = 0.0f;
    for (int b = tx; b < n_blocks_per_row; b += 32) {
        const uint8_t* block_ptr = W_row + b * 18;
        __half h_scale = *reinterpret_cast<const __half*>(block_ptr);
        float scale = __half2float(h_scale);
        float neg8_scale = scale * (-8.0f);
        int x_base = b * 33;

        // Load data as 8 x uint16 (matches PTX u16 approach)
        const uint16_t* data_u16 = reinterpret_cast<const uint16_t*>(block_ptr + 2);
        #pragma unroll
        for (int j = 0; j < 8; j++) {
            uint16_t val = data_u16[j];
            uint8_t b0 = val & 0xFF;
            uint8_t b1 = val >> 8;

            float w0 = (float)(b0 & 0xF) * scale + neg8_scale;
            float w1 = (float)(b0 >> 4) * scale + neg8_scale;
            float w2 = (float)(b1 & 0xF) * scale + neg8_scale;
            float w3 = (float)(b1 >> 4) * scale + neg8_scale;

            acc += w0 * x_smem[x_base + j * 4];
            acc += w1 * x_smem[x_base + j * 4 + 1];
            acc += w2 * x_smem[x_base + j * 4 + 2];
            acc += w3 * x_smem[x_base + j * 4 + 3];
        }
    }

    #pragma unroll
    for (int offset = 16; offset >= 1; offset >>= 1) {
        acc += __shfl_xor_sync(0xFFFFFFFF, acc, offset);
    }
    if (tx == 0) y[row] = acc;
}

// ============================================================================
// Benchmark harness
// ============================================================================
void benchmark_kernel(const char* name,
                      void (*launcher)(float*, const uint8_t*, const float*, int, int,
                                       int, int, int),
                      float* d_y, uint8_t* d_W, float* d_x,
                      int M, int K, int shared_bytes, int warmup, int iters) {
    int grid = (M + 7) / 8;

    // Warmup
    for (int i = 0; i < warmup; i++) {
        launcher(d_y, d_W, d_x, M, K, grid, 256, shared_bytes);
    }
    cudaDeviceSynchronize();

    // Timed runs
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    cudaEventRecord(start);

    for (int i = 0; i < iters; i++) {
        launcher(d_y, d_W, d_x, M, K, grid, 256, shared_bytes);
    }

    cudaEventRecord(stop);
    cudaEventSynchronize(stop);

    float ms;
    cudaEventElapsedTime(&ms, start, stop);
    float avg_ms = ms / iters;

    // Weight data per GEMV: M * (K/32) * 18 bytes
    float weight_bytes = (float)M * (K / 32) * 18;
    float bw_gbps = (weight_bytes / (avg_ms * 1e-3)) / 1e9;

    printf("  %-20s: %.3f ms  BW=%.1f GB/s\n", name, avg_ms, bw_gbps);

    cudaEventDestroy(start);
    cudaEventDestroy(stop);
}

void launch_v1(float* y, const uint8_t* W, const float* x, int M, int K,
               int grid, int block, int smem) {
    q4_0_gemv<<<grid, block, smem>>>(y, W, x, M, K);
}
void launch_v2(float* y, const uint8_t* W, const float* x, int M, int K,
               int grid, int block, int smem) {
    q4_0_gemv_v2<<<grid, block, smem>>>(y, W, x, M, K);
}

int main() {
    printf("Q4_0 GEMV Microbenchmark (nvcc-compiled vs hand PTX baseline)\n");
    printf("==============================================================\n");

    // Test configurations matching LLaMA-7B layers
    struct Config { int M; int K; const char* name; };
    Config configs[] = {
        {4096, 4096,  "QKV proj (4096x4096)"},
        {11008, 4096, "Gate/Up (11008x4096)"},
        {4096, 11008, "Down proj (4096x11008)"},
        {1024, 4096,  "KV proj (1024x4096)"},
        {32000, 4096, "LM head (32000x4096)"},
    };

    for (auto& cfg : configs) {
        int M = cfg.M, K = cfg.K;
        int n_blocks = K / 32;
        int row_bytes = n_blocks * 18;
        int shared_bytes = (K + K / 32) * 4;

        printf("\n%s: M=%d K=%d\n", cfg.name, M, K);

        // Allocate
        float *d_y, *d_x;
        uint8_t *d_W;
        cudaMalloc(&d_y, M * sizeof(float));
        cudaMalloc(&d_x, K * sizeof(float));
        cudaMalloc(&d_W, (size_t)M * row_bytes);
        cudaMemset(d_W, 0, (size_t)M * row_bytes);
        cudaMemset(d_x, 0, K * sizeof(float));

        benchmark_kernel("v1 (byte loop)",  launch_v1, d_y, d_W, d_x, M, K, shared_bytes, 10, 100);
        benchmark_kernel("v2 (u16 loop)",   launch_v2, d_y, d_W, d_x, M, K, shared_bytes, 10, 100);

        cudaFree(d_y);
        cudaFree(d_x);
        cudaFree(d_W);
    }

    printf("\nBaseline (hand PTX): 177 GB/s for 4096x4096\n");
    return 0;
}

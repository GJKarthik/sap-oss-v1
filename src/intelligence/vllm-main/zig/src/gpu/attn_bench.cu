// Decode Attention Microbenchmark: Current vs Flash Decoding
// Compile: nvcc -O3 -arch=sm_75 -o attn_bench attn_bench.cu && ./attn_bench
//
// Current kernel: 32 blocks (one per head), 256 threads, sequential V-sum
// Flash Decoding: 32*T blocks (heads × tiles), 256 threads, parallel tiles
//   - Each tile computes partial softmax + partial V-sum
//   - Lightweight reduction combines tiles using log-sum-exp

#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <cuda_runtime.h>

// ============================================================================
// Baseline: Current decode_attention kernel (1 block per head, 256 threads)
// ============================================================================
extern "C"
__global__ void decode_attn_baseline(
    float* __restrict__ out,        // [n_heads, head_dim]
    const float* __restrict__ Q,    // [n_heads, head_dim]
    const float* __restrict__ K,    // [seq, kv_dim]
    const float* __restrict__ V,    // [seq, kv_dim]
    int n_heads, int n_kv_heads, int head_dim, int kv_dim, int seq, float scale)
{
    extern __shared__ float smem[];
    int tid = threadIdx.x;
    int h = blockIdx.x;
    int gqa = n_heads / n_kv_heads;
    int kvh = h / gqa;

    float* q_smem = smem;                       // [head_dim]
    float* scores = smem + head_dim;             // [seq]
    float* scratch = scores + seq;               // [256]

    // Phase 0: Load Q into shared memory
    for (int d = tid; d < head_dim; d += 256)
        q_smem[d] = Q[h * head_dim + d];
    __syncthreads();

    // Phase 1: Compute scores (float4 vectorized)
    for (int t = tid; t < seq; t += 256) {
        float acc = 0.0f;
        const float* k_ptr = K + t * kv_dim + kvh * head_dim;
        for (int d = 0; d < head_dim; d += 4) {
            float4 q4 = *reinterpret_cast<const float4*>(&q_smem[d]);
            float4 k4 = __ldg(reinterpret_cast<const float4*>(&k_ptr[d]));
            acc += q4.x*k4.x + q4.y*k4.y + q4.z*k4.z + q4.w*k4.w;
        }
        scores[t] = acc * scale;
    }
    __syncthreads();

    // Phase 2: Softmax
    float local_max = -1e38f;
    for (int t = tid; t < seq; t += 256)
        local_max = fmaxf(local_max, scores[t]);
    scratch[tid] = local_max;
    __syncthreads();
    for (int s = 128; s > 0; s >>= 1) {
        if (tid < s) scratch[tid] = fmaxf(scratch[tid], scratch[tid + s]);
        __syncthreads();
    }
    float gmax = scratch[0];
    __syncthreads();

    float local_sum = 0.0f;
    for (int t = tid; t < seq; t += 256) {
        float e = expf(scores[t] - gmax);
        scores[t] = e;
        local_sum += e;
    }
    scratch[tid] = local_sum;
    __syncthreads();
    for (int s = 128; s > 0; s >>= 1) {
        if (tid < s) scratch[tid] += scratch[tid + s];
        __syncthreads();
    }
    float inv_sum = 1.0f / scratch[0];
    __syncthreads();

    for (int t = tid; t < seq; t += 256)
        scores[t] *= inv_sum;
    __syncthreads();

    // Phase 3: V-sum (2-way split: 256 threads for 128 dims)
    int n_splits = 256 / head_dim;  // 2
    int split_id = tid / head_dim;
    int d = tid % head_dim;
    int chunk = (seq + n_splits - 1) / n_splits;
    int t_start = split_id * chunk;
    int t_end = min(t_start + chunk, seq);

    float vacc = 0.0f;
    for (int t = t_start; t < t_end; t++) {
        vacc += scores[t] * V[t * kv_dim + kvh * head_dim + d];
    }

    scratch[tid] = vacc;
    __syncthreads();
    if (split_id == 0) {
        for (int s = 1; s < n_splits; s++)
            vacc += scratch[s * head_dim + d];
        out[h * head_dim + d] = vacc;
    }
}

// ============================================================================
// Flash Decoding: Split sequence into tiles, many blocks, parallel reduction
// Kernel 1: Per-tile partial attention
// Grid: (n_heads, n_tiles), Block: (256, 1)
// ============================================================================
extern "C"
__global__ void flash_decode_tiles(
    float* __restrict__ partial_out,  // [n_heads, n_tiles, head_dim]
    float* __restrict__ partial_max,  // [n_heads, n_tiles]
    float* __restrict__ partial_sum,  // [n_heads, n_tiles]
    const float* __restrict__ Q,      // [n_heads, head_dim]
    const float* __restrict__ K,      // [seq, kv_dim]
    const float* __restrict__ V,      // [seq, kv_dim]
    int n_heads, int n_kv_heads, int head_dim, int kv_dim, int seq, float scale,
    int tile_size)
{
    extern __shared__ float smem[];
    int tid = threadIdx.x;
    int h = blockIdx.x;
    int tile = blockIdx.y;
    int gqa = n_heads / n_kv_heads;
    int kvh = h / gqa;
    int n_tiles = gridDim.y;

    // Tile range
    int t_start = tile * tile_size;
    int t_end = min(t_start + tile_size, seq);
    int tile_len = t_end - t_start;
    if (tile_len <= 0) return;

    float* q_smem = smem;                // [head_dim]
    float* scores = smem + head_dim;     // [tile_size]
    float* scratch = scores + tile_size; // [256]

    // Load Q into shared memory
    for (int d = tid; d < head_dim; d += 256)
        q_smem[d] = Q[h * head_dim + d];
    __syncthreads();

    // Phase 1: Compute scores for this tile only
    for (int i = tid; i < tile_len; i += 256) {
        int t = t_start + i;
        float acc = 0.0f;
        const float* k_ptr = K + t * kv_dim + kvh * head_dim;
        for (int d = 0; d < head_dim; d += 4) {
            float4 q4 = *reinterpret_cast<const float4*>(&q_smem[d]);
            float4 k4 = __ldg(reinterpret_cast<const float4*>(&k_ptr[d]));
            acc += q4.x*k4.x + q4.y*k4.y + q4.z*k4.z + q4.w*k4.w;
        }
        scores[i] = acc * scale;
    }
    __syncthreads();

    // Phase 2: Online softmax within this tile
    float local_max = -1e38f;
    for (int i = tid; i < tile_len; i += 256)
        local_max = fmaxf(local_max, scores[i]);
    scratch[tid] = local_max;
    __syncthreads();
    for (int s = 128; s > 0; s >>= 1) {
        if (tid < s) scratch[tid] = fmaxf(scratch[tid], scratch[tid + s]);
        __syncthreads();
    }
    float tile_max = scratch[0];
    __syncthreads();

    float local_sum = 0.0f;
    for (int i = tid; i < tile_len; i += 256) {
        float e = expf(scores[i] - tile_max);
        scores[i] = e;
        local_sum += e;
    }
    scratch[tid] = local_sum;
    __syncthreads();
    for (int s = 128; s > 0; s >>= 1) {
        if (tid < s) scratch[tid] += scratch[tid + s];
        __syncthreads();
    }
    float tile_sum = scratch[0];
    __syncthreads();

    // Phase 3: Partial V-sum (split across threads)
    int n_splits = max(1, 256 / head_dim);
    int split_id = tid / head_dim;
    int d = tid % head_dim;
    if (split_id >= n_splits) { split_id = n_splits - 1; d = tid - split_id * head_dim; }
    int chunk = (tile_len + n_splits - 1) / n_splits;
    int vs = split_id * chunk;
    int ve = min(vs + chunk, tile_len);

    float vacc = 0.0f;
    for (int i = vs; i < ve; i++) {
        int t = t_start + i;
        vacc += scores[i] * V[t * kv_dim + kvh * head_dim + d];
    }

    scratch[tid] = vacc;
    __syncthreads();
    if (split_id == 0) {
        for (int s = 1; s < n_splits; s++)
            vacc += scratch[s * head_dim + d];
    }
    if (split_id == 0 && d < head_dim) {
        int idx = h * n_tiles * head_dim + tile * head_dim + d;
        partial_out[idx] = vacc;
    }

    // Store tile stats (one thread per tile)
    if (tid == 0) {
        partial_max[h * n_tiles + tile] = tile_max;
        partial_sum[h * n_tiles + tile] = tile_sum;
    }
}

// ============================================================================
// Flash Decoding Kernel 2: Combine tile partial results
// Grid: (n_heads, 1), Block: (head_dim, 1) — 128 threads
// ============================================================================
extern "C"
__global__ void flash_decode_reduce(
    float* __restrict__ out,            // [n_heads, head_dim]
    const float* __restrict__ partial_out, // [n_heads, n_tiles, head_dim]
    const float* __restrict__ partial_max, // [n_heads, n_tiles]
    const float* __restrict__ partial_sum, // [n_heads, n_tiles]
    int head_dim, int n_tiles)
{
    int h = blockIdx.x;
    int d = threadIdx.x;
    if (d >= head_dim) return;

    // Find global max across tiles
    float gmax = -1e38f;
    for (int t = 0; t < n_tiles; t++)
        gmax = fmaxf(gmax, partial_max[h * n_tiles + t]);

    // Combine: out[d] = sum_t(partial_out[t,d] * exp(tile_max[t] - gmax) * tile_sum[t]) / gsum
    // where gsum = sum_t(tile_sum[t] * exp(tile_max[t] - gmax))
    float gsum = 0.0f;
    float vacc = 0.0f;
    for (int t = 0; t < n_tiles; t++) {
        float correction = expf(partial_max[h * n_tiles + t] - gmax);
        float t_sum = partial_sum[h * n_tiles + t];
        gsum += t_sum * correction;
        vacc += partial_out[h * n_tiles * head_dim + t * head_dim + d] * correction;
    }
    out[h * head_dim + d] = vacc / gsum;
}

// ============================================================================
// Host benchmark
// ============================================================================
int main() {
    int n_heads = 32, n_kv_heads = 8, head_dim = 128;
    int kv_dim = n_kv_heads * head_dim;  // 1024

    int seq_lens[] = {500, 1000, 2000, 4000};
    int n_seq = sizeof(seq_lens) / sizeof(seq_lens[0]);

    for (int si = 0; si < n_seq; si++) {
        int seq = seq_lens[si];
        float scale = 1.0f / sqrtf((float)head_dim);

        // Allocate
        float *d_out, *d_out2, *d_Q, *d_K, *d_V;
        cudaMalloc(&d_out, n_heads * head_dim * 4);
        cudaMalloc(&d_out2, n_heads * head_dim * 4);
        cudaMalloc(&d_Q, n_heads * head_dim * 4);
        cudaMalloc(&d_K, seq * kv_dim * 4);
        cudaMalloc(&d_V, seq * kv_dim * 4);
        // Init with random data
        float* h_tmp = (float*)malloc(seq * kv_dim * 4);
        srand(42);
        for (int i = 0; i < seq * kv_dim; i++) h_tmp[i] = (float)(rand()%200-100)/1000.0f;
        cudaMemcpy(d_K, h_tmp, seq * kv_dim * 4, cudaMemcpyHostToDevice);
        cudaMemcpy(d_V, h_tmp, seq * kv_dim * 4, cudaMemcpyHostToDevice);
        for (int i = 0; i < n_heads * head_dim; i++) h_tmp[i] = (float)(rand()%200-100)/100.0f;
        cudaMemcpy(d_Q, h_tmp, n_heads * head_dim * 4, cudaMemcpyHostToDevice);

        // Flash decode tile params
        int tile_size = 256;
        int n_tiles = (seq + tile_size - 1) / tile_size;

        float *d_partial_out, *d_partial_max, *d_partial_sum;
        cudaMalloc(&d_partial_out, n_heads * n_tiles * head_dim * 4);
        cudaMalloc(&d_partial_max, n_heads * n_tiles * 4);
        cudaMalloc(&d_partial_sum, n_heads * n_tiles * 4);

        // Baseline config
        dim3 grid_base(n_heads);
        int smem_base = (head_dim + seq + 256) * 4;

        // Flash decode config
        dim3 grid_flash(n_heads, n_tiles);
        int smem_flash = (head_dim + tile_size + 256) * 4;
        dim3 grid_reduce(n_heads);

        // Warmup
        for (int i = 0; i < 5; i++) {
            decode_attn_baseline<<<grid_base, 256, smem_base>>>(
                d_out, d_Q, d_K, d_V, n_heads, n_kv_heads, head_dim, kv_dim, seq, scale);
            flash_decode_tiles<<<grid_flash, 256, smem_flash>>>(
                d_partial_out, d_partial_max, d_partial_sum,
                d_Q, d_K, d_V, n_heads, n_kv_heads, head_dim, kv_dim, seq, scale, tile_size);
            flash_decode_reduce<<<grid_reduce, head_dim>>>(
                d_out2, d_partial_out, d_partial_max, d_partial_sum, head_dim, n_tiles);
        }
        cudaDeviceSynchronize();
        cudaError_t err = cudaGetLastError();
        if (err != cudaSuccess) printf("  Error: %s\n", cudaGetErrorString(err));

        // Correctness check
        float* h_out1 = (float*)malloc(n_heads * head_dim * 4);
        float* h_out2 = (float*)malloc(n_heads * head_dim * 4);
        cudaMemcpy(h_out1, d_out, n_heads * head_dim * 4, cudaMemcpyDeviceToHost);
        cudaMemcpy(h_out2, d_out2, n_heads * head_dim * 4, cudaMemcpyDeviceToHost);
        float max_err = 0;
        for (int i = 0; i < n_heads * head_dim; i++)
            max_err = fmaxf(max_err, fabsf(h_out1[i] - h_out2[i]));

        // Benchmark
        int n_iters = 500;
        cudaEvent_t start, stop;
        cudaEventCreate(&start);
        cudaEventCreate(&stop);

        cudaEventRecord(start);
        for (int i = 0; i < n_iters; i++)
            decode_attn_baseline<<<grid_base, 256, smem_base>>>(
                d_out, d_Q, d_K, d_V, n_heads, n_kv_heads, head_dim, kv_dim, seq, scale);
        cudaEventRecord(stop);
        cudaEventSynchronize(stop);
        float ms_base; cudaEventElapsedTime(&ms_base, start, stop); ms_base /= n_iters;

        cudaEventRecord(start);
        for (int i = 0; i < n_iters; i++) {
            flash_decode_tiles<<<grid_flash, 256, smem_flash>>>(
                d_partial_out, d_partial_max, d_partial_sum,
                d_Q, d_K, d_V, n_heads, n_kv_heads, head_dim, kv_dim, seq, scale, tile_size);
            flash_decode_reduce<<<grid_reduce, head_dim>>>(
                d_out2, d_partial_out, d_partial_max, d_partial_sum, head_dim, n_tiles);
        }
        cudaEventRecord(stop);
        cudaEventSynchronize(stop);
        float ms_flash; cudaEventElapsedTime(&ms_flash, start, stop); ms_flash /= n_iters;

        printf("seq=%4d: baseline=%.3f ms  flash_decode=%.3f ms  speedup=%.2fx  max_err=%.6f  (tiles=%d, blocks=%d vs %d)\n",
               seq, ms_base, ms_flash, ms_base/ms_flash, max_err, n_tiles, n_heads*n_tiles, n_heads);

        cudaEventDestroy(start);
        cudaEventDestroy(stop);
        cudaFree(d_out); cudaFree(d_out2); cudaFree(d_Q); cudaFree(d_K); cudaFree(d_V);
        cudaFree(d_partial_out); cudaFree(d_partial_max); cudaFree(d_partial_sum);
        free(h_tmp); free(h_out1); free(h_out2);
    }
    return 0;
}

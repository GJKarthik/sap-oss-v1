// Full-stack 7B layer simulation with FP16 HGEMM
//
// Simulates 32 transformer layers with pre-dequanted FP16 weights.
// Measures real per-layer and full-model cost with kernel launch overhead.
// Tests batch sizes 1, 4, 8 to confirm DART viability.
//
// Compile: nvcc -O3 -arch=sm_75 -lcublas -o fp16_layer_bench fp16_layer_bench.cu

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cmath>
#include <cuda_runtime.h>
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

// LLaMA-7B dimensions
const int DIM = 4096;
const int FF_DIM = 11008;
const int N_HEADS = 32;
const int N_KV_HEADS = 32;
const int HEAD_DIM = DIM / N_HEADS;
const int N_LAYERS = 32;

struct LayerWeights {
    __half *wq, *wk, *wv, *wo;         // [DIM × DIM] each
    __half *w_gate, *w_up, *w_down;     // [FF_DIM × DIM], [FF_DIM × DIM], [DIM × FF_DIM]
};

struct Activations {
    __half *hidden;     // [B × DIM]
    __half *q, *k, *v;  // [B × DIM]
    __half *attn_out;   // [B × DIM]
    __half *gate_out, *up_out;  // [B × FF_DIM]
    __half *ffn_out;    // [B × DIM]
    __half *scratch;    // temp
};

// Simulate one layer: 7 GEMM operations + overhead
// Returns time in ms
float bench_one_layer(cublasHandle_t handle, LayerWeights& w, Activations& act,
                       int B, int n_iters) {
    __half alpha = __float2half(1.0f);
    __half beta = __float2half(0.0f);

    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    // Warmup
    for (int i = 0; i < 5; i++) {
        // Q projection: [DIM × DIM] × [DIM × B] → [DIM × B]
        cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, DIM, B, DIM, &alpha,
                     w.wq, DIM, act.hidden, DIM, &beta, act.q, DIM);
        // K projection
        cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, DIM, B, DIM, &alpha,
                     w.wk, DIM, act.hidden, DIM, &beta, act.k, DIM);
        // V projection
        cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, DIM, B, DIM, &alpha,
                     w.wv, DIM, act.hidden, DIM, &beta, act.v, DIM);
        // O projection (attn_out → hidden residual)
        cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, DIM, B, DIM, &alpha,
                     w.wo, DIM, act.q, DIM, &beta, act.attn_out, DIM);
        // FFN gate
        cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, FF_DIM, B, DIM, &alpha,
                     w.w_gate, FF_DIM, act.hidden, DIM, &beta, act.gate_out, FF_DIM);
        // FFN up
        cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, FF_DIM, B, DIM, &alpha,
                     w.w_up, FF_DIM, act.hidden, DIM, &beta, act.up_out, FF_DIM);
        // FFN down
        cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, DIM, B, FF_DIM, &alpha,
                     w.w_down, DIM, act.gate_out, FF_DIM, &beta, act.ffn_out, DIM);
    }
    CHECK_CUDA(cudaDeviceSynchronize());

    // Benchmark
    cudaEventRecord(start);
    for (int i = 0; i < n_iters; i++) {
        cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, DIM, B, DIM, &alpha,
                     w.wq, DIM, act.hidden, DIM, &beta, act.q, DIM);
        cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, DIM, B, DIM, &alpha,
                     w.wk, DIM, act.hidden, DIM, &beta, act.k, DIM);
        cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, DIM, B, DIM, &alpha,
                     w.wv, DIM, act.hidden, DIM, &beta, act.v, DIM);
        cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, DIM, B, DIM, &alpha,
                     w.wo, DIM, act.q, DIM, &beta, act.attn_out, DIM);
        cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, FF_DIM, B, DIM, &alpha,
                     w.w_gate, FF_DIM, act.hidden, DIM, &beta, act.gate_out, FF_DIM);
        cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, FF_DIM, B, DIM, &alpha,
                     w.w_up, FF_DIM, act.hidden, DIM, &beta, act.up_out, FF_DIM);
        cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, DIM, B, FF_DIM, &alpha,
                     w.w_down, DIM, act.gate_out, FF_DIM, &beta, act.ffn_out, DIM);
    }
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);

    float ms;
    cudaEventElapsedTime(&ms, start, stop);
    cudaEventDestroy(start);
    cudaEventDestroy(stop);

    return ms / n_iters;
}

// Simulate full model: 32 layers with different weight pointers
float bench_full_model(cublasHandle_t handle, LayerWeights* layers, Activations& act,
                        int B, int n_iters) {
    __half alpha = __float2half(1.0f);
    __half beta = __float2half(0.0f);

    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    // Warmup
    for (int w = 0; w < 3; w++) {
        for (int l = 0; l < N_LAYERS; l++) {
            LayerWeights& lw = layers[l];
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, DIM, B, DIM, &alpha,
                         lw.wq, DIM, act.hidden, DIM, &beta, act.q, DIM);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, DIM, B, DIM, &alpha,
                         lw.wk, DIM, act.hidden, DIM, &beta, act.k, DIM);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, DIM, B, DIM, &alpha,
                         lw.wv, DIM, act.hidden, DIM, &beta, act.v, DIM);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, DIM, B, DIM, &alpha,
                         lw.wo, DIM, act.q, DIM, &beta, act.attn_out, DIM);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, FF_DIM, B, DIM, &alpha,
                         lw.w_gate, FF_DIM, act.hidden, DIM, &beta, act.gate_out, FF_DIM);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, FF_DIM, B, DIM, &alpha,
                         lw.w_up, FF_DIM, act.hidden, DIM, &beta, act.up_out, FF_DIM);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, DIM, B, FF_DIM, &alpha,
                         lw.w_down, DIM, act.gate_out, FF_DIM, &beta, act.ffn_out, DIM);
        }
    }
    CHECK_CUDA(cudaDeviceSynchronize());

    // Benchmark
    cudaEventRecord(start);
    for (int i = 0; i < n_iters; i++) {
        for (int l = 0; l < N_LAYERS; l++) {
            LayerWeights& lw = layers[l];
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, DIM, B, DIM, &alpha,
                         lw.wq, DIM, act.hidden, DIM, &beta, act.q, DIM);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, DIM, B, DIM, &alpha,
                         lw.wk, DIM, act.hidden, DIM, &beta, act.k, DIM);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, DIM, B, DIM, &alpha,
                         lw.wv, DIM, act.hidden, DIM, &beta, act.v, DIM);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, DIM, B, DIM, &alpha,
                         lw.wo, DIM, act.q, DIM, &beta, act.attn_out, DIM);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, FF_DIM, B, DIM, &alpha,
                         lw.w_gate, FF_DIM, act.hidden, DIM, &beta, act.gate_out, FF_DIM);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, FF_DIM, B, DIM, &alpha,
                         lw.w_up, FF_DIM, act.hidden, DIM, &beta, act.up_out, FF_DIM);
            cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, DIM, B, FF_DIM, &alpha,
                         lw.w_down, DIM, act.gate_out, FF_DIM, &beta, act.ffn_out, DIM);
        }
    }
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);

    float ms;
    cudaEventElapsedTime(&ms, start, stop);
    cudaEventDestroy(start);
    cudaEventDestroy(stop);

    return ms / n_iters;
}

int main() {
    int dev;
    cudaGetDevice(&dev);
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, dev);

    size_t free_mem, total_mem;
    cudaMemGetInfo(&free_mem, &total_mem);

    printf("GPU: %s  VRAM: %.1f GB free / %.1f GB total\n",
           prop.name, free_mem / 1e9, total_mem / 1e9);

    // Calculate memory needed for full 32-layer model in FP16
    size_t per_layer_bytes = (size_t)(
        4ULL * DIM * DIM * 2 +           // Q,K,V,O
        2ULL * FF_DIM * DIM * 2 +         // gate, up
        1ULL * DIM * FF_DIM * 2            // down
    );
    size_t total_weight_bytes = per_layer_bytes * N_LAYERS;
    printf("FP16 weights: %.1f MB per layer, %.1f GB total (%d layers)\n",
           per_layer_bytes / 1e6, total_weight_bytes / 1e9, N_LAYERS);

    if (total_weight_bytes > free_mem * 0.9) {
        printf("WARNING: Not enough VRAM for full model! Need %.1f GB, have %.1f GB free\n",
               total_weight_bytes / 1e9, free_mem / 1e9);
        printf("Reducing to fit...\n");
    }

    // Allocate weights for all 32 layers
    LayerWeights layers[N_LAYERS];
    size_t allocated = 0;

    for (int l = 0; l < N_LAYERS; l++) {
        CHECK_CUDA(cudaMalloc(&layers[l].wq, (size_t)DIM * DIM * 2));
        CHECK_CUDA(cudaMalloc(&layers[l].wk, (size_t)DIM * DIM * 2));
        CHECK_CUDA(cudaMalloc(&layers[l].wv, (size_t)DIM * DIM * 2));
        CHECK_CUDA(cudaMalloc(&layers[l].wo, (size_t)DIM * DIM * 2));
        CHECK_CUDA(cudaMalloc(&layers[l].w_gate, (size_t)FF_DIM * DIM * 2));
        CHECK_CUDA(cudaMalloc(&layers[l].w_up, (size_t)FF_DIM * DIM * 2));
        CHECK_CUDA(cudaMalloc(&layers[l].w_down, (size_t)DIM * FF_DIM * 2));
        allocated += per_layer_bytes;
    }

    printf("Allocated: %.1f GB for weights\n", allocated / 1e9);
    cudaMemGetInfo(&free_mem, &total_mem);
    printf("VRAM remaining: %.1f GB free\n", free_mem / 1e9);

    // Allocate activations (max batch = 16)
    int max_B = 16;
    Activations act;
    CHECK_CUDA(cudaMalloc(&act.hidden, (size_t)max_B * DIM * 2));
    CHECK_CUDA(cudaMalloc(&act.q, (size_t)max_B * DIM * 2));
    CHECK_CUDA(cudaMalloc(&act.k, (size_t)max_B * DIM * 2));
    CHECK_CUDA(cudaMalloc(&act.v, (size_t)max_B * DIM * 2));
    CHECK_CUDA(cudaMalloc(&act.attn_out, (size_t)max_B * DIM * 2));
    CHECK_CUDA(cudaMalloc(&act.gate_out, (size_t)max_B * FF_DIM * 2));
    CHECK_CUDA(cudaMalloc(&act.up_out, (size_t)max_B * FF_DIM * 2));
    CHECK_CUDA(cudaMalloc(&act.ffn_out, (size_t)max_B * DIM * 2));
    CHECK_CUDA(cudaMalloc(&act.scratch, (size_t)max_B * FF_DIM * 2));

    cublasHandle_t handle;
    CHECK_CUBLAS(cublasCreate(&handle));
    // Enable tensor cores
    CHECK_CUBLAS(cublasSetMathMode(handle, CUBLAS_TENSOR_OP_MATH));

    printf("\n=== Single Layer Benchmark (7 HGEMM ops) ===\n");
    for (int B : {1, 2, 4, 8, 16}) {
        float ms = bench_one_layer(handle, layers[0], act, B, 100);
        printf("  B=%2d: %.3f ms/layer  effective=%.0f tok/s (per layer)\n",
               B, ms, (float)B / ms * 1000.0f);
    }

    printf("\n=== Full 32-Layer Model Benchmark (224 HGEMM ops) ===\n");
    for (int B : {1, 2, 4, 8, 16}) {
        int iters = (B <= 4) ? 20 : 10;
        float ms = bench_full_model(handle, layers, act, B, iters);
        float tps_raw = (float)B / ms * 1000.0f;

        // DART estimates (add ~0.15ms/layer overhead for attention, norms, etc.)
        float overhead_ms = N_LAYERS * 0.15f * B;  // scales with B
        float total_ms = ms + overhead_ms;

        printf("  B=%2d: GEMM=%.1f ms  +overhead=%.1f ms  total=%.1f ms  raw_tps=%.0f\n",
               B, ms, overhead_ms, total_ms, tps_raw);

        // DART TPS estimates at various acceptance rates
        if (B > 1) {
            int K = B;
            for (float alpha : {0.5f, 0.7f, 0.9f}) {
                float accepted = alpha * K + 1;
                float dart_tps = accepted / total_ms * 1000.0f;
                printf("         DART K=%d α=%.1f: %.1f accepted → %.0f effective TPS\n",
                       K, alpha, accepted, dart_tps);
            }
        }
    }

    // Cleanup
    cublasDestroy(handle);
    for (int l = 0; l < N_LAYERS; l++) {
        cudaFree(layers[l].wq);
        cudaFree(layers[l].wk);
        cudaFree(layers[l].wv);
        cudaFree(layers[l].wo);
        cudaFree(layers[l].w_gate);
        cudaFree(layers[l].w_up);
        cudaFree(layers[l].w_down);
    }
    cudaFree(act.hidden);
    cudaFree(act.q);
    cudaFree(act.k);
    cudaFree(act.v);
    cudaFree(act.attn_out);
    cudaFree(act.gate_out);
    cudaFree(act.up_out);
    cudaFree(act.ffn_out);
    cudaFree(act.scratch);

    return 0;
}

// Multi-User Batched Throughput Benchmark for T4
//
// Measures how throughput scales with concurrent users using POD-style batching.
// Key insight: batched decode turns GEMV into GEMM, shifting from
// memory-bandwidth-bound to compute-bound at higher batch sizes.
//
// For LLaMA-7B Q4_0 on T4:
//   Single user:  GEMV (bandwidth-limited) → ~47 TPS
//   Multi-user:   GEMM (compute-limited)   → higher aggregate TPS
//
// Also measures prefill throughput and prefill/decode overlap potential.

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <cuda_runtime.h>
#include <cuda_fp16.h>

// ============================================================================
// Batched Q4_0 GEMV — processes B input vectors simultaneously
// Each block handles 8 output rows for ONE user; grid.y = batch size
// Weight matrix is shared across all users (same model weights)
// ============================================================================
__global__ void q4_0_batched_gemv(
    float* __restrict__ Y,       // [B, M] output
    const uint8_t* __restrict__ W, // [M, K/32 * 18] weights (shared)
    const float* __restrict__ X,   // [B, K] input vectors
    int M, int K, int B)
{
    extern __shared__ float x_smem[];
    int tid = threadIdx.x;
    int batch_idx = blockIdx.y;
    if (batch_idx >= B) return;

    const float* x_in = X + batch_idx * K;
    float* y_out = Y + batch_idx * M;

    int n_blocks_per_row = K / 32;

    // Cooperative x[] load into shared memory (padded)
    for (int idx = tid; idx < K; idx += 256) {
        int padded = idx + (idx >> 5);
        x_smem[padded] = x_in[idx];
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

        const uint16_t* data_u16 = reinterpret_cast<const uint16_t*>(block_ptr + 2);
        #pragma unroll
        for (int j = 0; j < 8; j++) {
            uint16_t val = data_u16[j];
            uint8_t b0 = val & 0xFF;
            uint8_t b1 = val >> 8;
            acc += ((float)(b0 & 0xF) * scale + neg8_scale) * x_smem[x_base + j * 4];
            acc += ((float)(b0 >> 4) * scale + neg8_scale) * x_smem[x_base + j * 4 + 1];
            acc += ((float)(b1 & 0xF) * scale + neg8_scale) * x_smem[x_base + j * 4 + 2];
            acc += ((float)(b1 >> 4) * scale + neg8_scale) * x_smem[x_base + j * 4 + 3];
        }
    }

    #pragma unroll
    for (int offset = 16; offset >= 1; offset >>= 1)
        acc += __shfl_xor_sync(0xFFFFFFFF, acc, offset);

    if (tx == 0) y_out[row] = acc;
}

// ============================================================================
// Run one batched forward pass (all 7 GEMVs for one layer, for B users)
// ============================================================================
struct LayerWeights {
    uint8_t *d_wq, *d_wk, *d_wv, *d_wo;
    uint8_t *d_wgate, *d_wup, *d_wdown;
};

void run_batched_layer(LayerWeights& w, float* d_X, float* d_Y, float* d_tmp,
                       int dim, int ffn_dim, int B,
                       int smem_dim, int smem_ffn) {
    dim3 grid_dim((dim + 7) / 8, B);
    dim3 grid_ffn((ffn_dim + 7) / 8, B);

    // QKV projections (3× dim→dim)
    q4_0_batched_gemv<<<grid_dim, 256, smem_dim>>>(d_Y, w.d_wq, d_X, dim, dim, B);
    q4_0_batched_gemv<<<grid_dim, 256, smem_dim>>>(d_Y, w.d_wk, d_X, dim, dim, B);
    q4_0_batched_gemv<<<grid_dim, 256, smem_dim>>>(d_Y, w.d_wv, d_X, dim, dim, B);
    // Output projection (dim→dim)
    q4_0_batched_gemv<<<grid_dim, 256, smem_dim>>>(d_Y, w.d_wo, d_tmp, dim, dim, B);
    // FFN gate + up (dim→ffn_dim)
    q4_0_batched_gemv<<<grid_ffn, 256, smem_dim>>>(d_Y, w.d_wgate, d_X, ffn_dim, dim, B);
    q4_0_batched_gemv<<<grid_ffn, 256, smem_dim>>>(d_Y, w.d_wup, d_X, ffn_dim, dim, B);
    // FFN down (ffn_dim→dim)
    q4_0_batched_gemv<<<grid_dim, 256, smem_ffn>>>(d_Y, w.d_wdown, d_tmp, dim, ffn_dim, B);
}

int main() {
    printf("Multi-User Batched Throughput Benchmark (T4)\n");
    printf("=============================================\n\n");

    const int dim = 4096;
    const int ffn_dim = 11008;
    const int n_layers = 32;
    const int max_batch = 16;

    int smem_dim = (dim + dim / 32) * sizeof(float);
    int smem_ffn = (ffn_dim + ffn_dim / 32) * sizeof(float);

    // Weight sizes
    size_t w_dim_bytes = (size_t)dim * (dim / 32) * 18;
    size_t w_ffn_up_bytes = (size_t)ffn_dim * (dim / 32) * 18;
    size_t w_ffn_down_bytes = (size_t)dim * (ffn_dim / 32) * 18;
    size_t total_weight_bytes = (4 * w_dim_bytes + 2 * w_ffn_up_bytes + w_ffn_down_bytes) * n_layers;

    printf("Model: LLaMA-7B Q4_0, %d layers\n", n_layers);
    printf("Total model weight: %.1f GB\n", total_weight_bytes / 1e9);
    printf("T4 VRAM: 15 GB, available for KV: ~%.1f GB\n\n",
           15.0 - total_weight_bytes / 1e9);

    // Allocate layer weights
    LayerWeights lw;
    cudaMalloc(&lw.d_wq, w_dim_bytes);
    cudaMalloc(&lw.d_wk, w_dim_bytes);
    cudaMalloc(&lw.d_wv, w_dim_bytes);
    cudaMalloc(&lw.d_wo, w_dim_bytes);
    cudaMalloc(&lw.d_wgate, w_ffn_up_bytes);
    cudaMalloc(&lw.d_wup, w_ffn_up_bytes);
    cudaMalloc(&lw.d_wdown, w_ffn_down_bytes);

    // Zero-init weights
    cudaMemset(lw.d_wq, 0, w_dim_bytes);
    cudaMemset(lw.d_wk, 0, w_dim_bytes);
    cudaMemset(lw.d_wv, 0, w_dim_bytes);
    cudaMemset(lw.d_wo, 0, w_dim_bytes);
    cudaMemset(lw.d_wgate, 0, w_ffn_up_bytes);
    cudaMemset(lw.d_wup, 0, w_ffn_up_bytes);
    cudaMemset(lw.d_wdown, 0, w_ffn_down_bytes);

    // Activation buffers (max_batch × max(dim, ffn_dim))
    float *d_X, *d_Y, *d_tmp;
    cudaMalloc(&d_X, max_batch * ffn_dim * sizeof(float));
    cudaMalloc(&d_Y, max_batch * ffn_dim * sizeof(float));
    cudaMalloc(&d_tmp, max_batch * ffn_dim * sizeof(float));
    cudaMemset(d_X, 0, max_batch * ffn_dim * sizeof(float));

    cudaEvent_t t0, t1;
    cudaEventCreate(&t0);
    cudaEventCreate(&t1);

    // ========================================================================
    // Phase 1: Batched decode throughput (GEMV → GEMM transition)
    // ========================================================================
    printf("=== Phase 1: Batched Decode Throughput ===\n\n");
    printf("%-8s  %-12s  %-12s  %-12s  %-12s\n",
           "Users", "ms/iter", "TPS/user", "Agg TPS", "Scaling");
    printf("%-8s  %-12s  %-12s  %-12s  %-12s\n",
           "-----", "-------", "--------", "-------", "-------");

    float single_user_tps = 0.0f;

    int batch_sizes[] = {1, 2, 4, 6, 8, 10, 12, 16};
    int n_batches = 8;

    for (int bi = 0; bi < n_batches; bi++) {
        int B = batch_sizes[bi];

        // Warmup
        for (int w = 0; w < 3; w++) {
            for (int l = 0; l < n_layers; l++)
                run_batched_layer(lw, d_X, d_Y, d_tmp, dim, ffn_dim, B, smem_dim, smem_ffn);
        }
        cudaDeviceSynchronize();

        int N_iters = 30;
        cudaEventRecord(t0);
        for (int i = 0; i < N_iters; i++) {
            for (int l = 0; l < n_layers; l++)
                run_batched_layer(lw, d_X, d_Y, d_tmp, dim, ffn_dim, B, smem_dim, smem_ffn);
        }
        cudaEventRecord(t1);
        cudaEventSynchronize(t1);

        float total_ms;
        cudaEventElapsedTime(&total_ms, t0, t1);
        float ms_per_iter = total_ms / N_iters;
        float tps_per_user = 1000.0f / ms_per_iter;
        float agg_tps = tps_per_user * B;

        if (B == 1) single_user_tps = tps_per_user;
        float scaling = agg_tps / (single_user_tps * B);

        printf("B=%-6d  %8.2f ms  %8.1f      %8.1f      %.2fx\n",
               B, ms_per_iter, tps_per_user, agg_tps, scaling);
    }
    printf("\n");

    // ========================================================================
    // Phase 2: Prefill throughput (processing prompt tokens)
    // Prefill = many tokens through one layer = GEMM workload
    // ========================================================================
    printf("=== Phase 2: Prefill Throughput (single user) ===\n\n");

    // For prefill, we process P tokens through each layer
    // This is P independent GEMV calls, which can be batched as GEMM
    // Using our batched kernel with B=prompt_length
    int prefill_lengths[] = {32, 64, 128, 256, 512};
    int n_prefills = 5;

    printf("%-12s  %-12s  %-12s\n", "Prompt Len", "Time(ms)", "Tok/sec");
    printf("%-12s  %-12s  %-12s\n", "----------", "-------", "-------");

    for (int pi = 0; pi < n_prefills; pi++) {
        int P = prefill_lengths[pi];

        // Ensure buffer is large enough
        float *d_PX, *d_PY, *d_Ptmp;
        cudaMalloc(&d_PX, P * ffn_dim * sizeof(float));
        cudaMalloc(&d_PY, P * ffn_dim * sizeof(float));
        cudaMalloc(&d_Ptmp, P * ffn_dim * sizeof(float));
        cudaMemset(d_PX, 0, P * ffn_dim * sizeof(float));

        // Warmup
        for (int l = 0; l < n_layers; l++)
            run_batched_layer(lw, d_PX, d_PY, d_Ptmp, dim, ffn_dim, P, smem_dim, smem_ffn);
        cudaDeviceSynchronize();

        int N_iters = 10;
        cudaEventRecord(t0);
        for (int i = 0; i < N_iters; i++) {
            for (int l = 0; l < n_layers; l++)
                run_batched_layer(lw, d_PX, d_PY, d_Ptmp, dim, ffn_dim, P, smem_dim, smem_ffn);
        }
        cudaEventRecord(t1);
        cudaEventSynchronize(t1);

        float total_ms;
        cudaEventElapsedTime(&total_ms, t0, t1);
        float ms_prefill = total_ms / N_iters;
        float prefill_tps = P * 1000.0f / ms_prefill;

        printf("P=%-10d  %8.1f ms  %8.0f\n", P, ms_prefill, prefill_tps);

        cudaFree(d_PX); cudaFree(d_PY); cudaFree(d_Ptmp);
    }
    printf("\n");

    // ========================================================================
    // Phase 3: POD Simulation — Prefill + Decode overlap
    // ========================================================================
    printf("=== Phase 3: POD Scheduling Simulation ===\n\n");

    // Simulate a steady-state scenario:
    // - N_active users in decode phase
    // - 1 new user arriving (needs prefill of P=256 tokens)
    // - POD partitions SMs: some for prefill, rest for decode
    //
    // Without POD: prefill blocks decode → all active users stall
    // With POD: prefill runs on subset of SMs, decode continues on rest

    float ms_single_decode;  // single-user decode time
    {
        int N_iters = 50;
        cudaEventRecord(t0);
        for (int i = 0; i < N_iters; i++) {
            for (int l = 0; l < n_layers; l++)
                run_batched_layer(lw, d_X, d_Y, d_tmp, dim, ffn_dim, 1, smem_dim, smem_ffn);
        }
        cudaEventRecord(t1);
        cudaEventSynchronize(t1);
        float total_ms;
        cudaEventElapsedTime(&total_ms, t0, t1);
        ms_single_decode = total_ms / N_iters;
    }

    printf("Single-user decode: %.2f ms/token\n\n", ms_single_decode);

    int active_users_sweep[] = {1, 2, 4, 8};
    int n_active = 4;
    int prefill_prompt = 256;

    printf("Scenario: %d-token prefill arrives while N users are decoding\n\n", prefill_prompt);
    printf("%-8s  %-14s  %-14s  %-14s  %-10s\n",
           "N_dec", "No POD(ms)", "POD Est(ms)", "Dec Stall", "POD Gain");
    printf("%-8s  %-14s  %-14s  %-14s  %-10s\n",
           "-----", "----------", "-----------", "---------", "--------");

    for (int ni = 0; ni < n_active; ni++) {
        int N_dec = active_users_sweep[ni];

        // Without POD: prefill runs first, then decode
        // Prefill cost: P tokens × ms_single_decode (sequential through layers)
        float prefill_ms = prefill_prompt * ms_single_decode;
        // During prefill, all N_dec users stall
        float no_pod_total = prefill_ms + ms_single_decode; // prefill then one decode step
        float decode_stall_ms = prefill_ms; // decode users wait this long

        // With POD: partition SMs
        // Prefill gets min_prefill_sms=4 of 40 SMs → 10% compute
        // Decode gets 36 of 40 SMs → 90% compute
        // Prefill time increases by 40/4 = 10× but decode only slows by 40/36 = 1.11×
        float prefill_sm_frac = 4.0f / 40.0f;
        float decode_sm_frac = 36.0f / 40.0f;

        // Prefill time with reduced SMs (compute-bound, scales linearly with SM count)
        float pod_prefill_ms = prefill_ms / prefill_sm_frac * (1.0f / 40.0f);
        // Actually: prefill on 4 SMs takes 10× longer than on 40 SMs
        pod_prefill_ms = prefill_ms * (40.0f / 4.0f);

        // But decode continues during this time with slight slowdown
        float pod_decode_ms = ms_single_decode / decode_sm_frac;

        // Number of decode steps that complete during prefill
        int decode_steps_during_prefill = (int)(pod_prefill_ms / pod_decode_ms);

        // Effective: users get decode_steps tokens during what would have been a stall
        float pod_total = fmaxf(pod_prefill_ms, pod_decode_ms); // overlapped

        // Decode stall with POD = 0 (decode keeps running, just slower)
        float pod_decode_stall = 0.0f;

        // POD gain = tokens generated during prefill
        float tokens_during_prefill = decode_steps_during_prefill * N_dec;

        printf("N=%-6d  %8.1f ms    %8.1f ms    %8.1f ms    %d tok saved\n",
               N_dec, no_pod_total, pod_total, decode_stall_ms,
               (int)tokens_during_prefill);
    }
    printf("\n");

    // ========================================================================
    // Phase 4: End-to-end multi-user throughput projection
    // ========================================================================
    printf("=== Phase 4: Projected Multi-User Throughput ===\n\n");

    printf("Scenario: N concurrent users, each generating 100 tokens\n");
    printf("  Prompt: 256 tokens, DART α=0.7 K=4\n\n");

    float dart_head_ms = 0.1f;
    float tree_overhead = 1.1f;
    float alpha = 0.7f;
    int K_draft = 4;
    float expected_per_cycle = alpha * (1.0f - powf(alpha, K_draft)) / (1.0f - alpha) + 1.0f;

    printf("%-8s  %-10s  %-10s  %-14s  %-10s\n",
           "Users", "Agg TPS", "TPS/user", "DART Agg TPS", "DART/user");
    printf("%-8s  %-10s  %-10s  %-14s  %-10s\n",
           "-----", "-------", "--------", "------------", "---------");

    for (int bi = 0; bi < n_batches; bi++) {
        int B = batch_sizes[bi];

        // Measure actual batched decode time
        for (int w = 0; w < 3; w++) {
            for (int l = 0; l < n_layers; l++)
                run_batched_layer(lw, d_X, d_Y, d_tmp, dim, ffn_dim, B, smem_dim, smem_ffn);
        }
        cudaDeviceSynchronize();

        int N_iters = 20;
        cudaEventRecord(t0);
        for (int i = 0; i < N_iters; i++) {
            for (int l = 0; l < n_layers; l++)
                run_batched_layer(lw, d_X, d_Y, d_tmp, dim, ffn_dim, B, smem_dim, smem_ffn);
        }
        cudaEventRecord(t1);
        cudaEventSynchronize(t1);

        float total_ms;
        cudaEventElapsedTime(&total_ms, t0, t1);
        float ms_batch = total_ms / N_iters;

        float agg_tps = B * 1000.0f / ms_batch;
        float per_user_tps = 1000.0f / ms_batch;

        // DART projection: each cycle produces expected_per_cycle tokens
        float dart_cycle_ms = ms_batch + dart_head_ms + ms_batch * tree_overhead;
        float dart_agg_tps = B * expected_per_cycle * 1000.0f / dart_cycle_ms;
        float dart_per_user_tps = expected_per_cycle * 1000.0f / dart_cycle_ms;

        printf("B=%-6d  %8.1f    %8.1f    %10.1f      %8.1f\n",
               B, agg_tps, per_user_tps, dart_agg_tps, dart_per_user_tps);
    }
    printf("\n");

    // ========================================================================
    // Phase 5: VRAM budget analysis
    // ========================================================================
    printf("=== Phase 5: VRAM Budget (T4 = 15 GB) ===\n\n");

    float vram_total_gb = 15.0f;
    float model_gb = total_weight_bytes / 1e9f;
    float activations_gb = 0.1f; // ~100MB for activations
    float available_gb = vram_total_gb - model_gb - activations_gb;

    // KV cache per user per layer: 2 × dim × sizeof(float) × 2 (K and V)
    // For context length C: 2 × dim × C × sizeof(float) per layer
    float kv_per_token_per_layer = 2.0f * dim * sizeof(float); // K + V
    float kv_per_token_all_layers = kv_per_token_per_layer * n_layers;
    float kv_per_token_mb = kv_per_token_all_layers / 1e6f;

    printf("  Model weights: %.2f GB\n", model_gb);
    printf("  Activations:   %.2f GB\n", activations_gb);
    printf("  Available KV:  %.2f GB\n", available_gb);
    printf("  KV per token:  %.3f MB (all layers)\n\n", kv_per_token_mb);

    int context_lengths[] = {256, 512, 1024, 2048};
    int n_ctx = 4;

    printf("%-8s  ", "Users");
    for (int ci = 0; ci < n_ctx; ci++)
        printf("ctx=%-6d  ", context_lengths[ci]);
    printf("\n");
    printf("%-8s  ", "-----");
    for (int ci = 0; ci < n_ctx; ci++)
        printf("----------  ");
    printf("\n");

    for (int bi = 0; bi < n_batches; bi++) {
        int B = batch_sizes[bi];
        printf("B=%-6d  ", B);
        for (int ci = 0; ci < n_ctx; ci++) {
            int ctx = context_lengths[ci];
            float kv_gb = B * ctx * kv_per_token_all_layers / 1e9f;
            const char* status = (kv_gb <= available_gb) ? "OK" : "OOM";
            printf("%5.2f GB %s  ", kv_gb, status);
        }
        printf("\n");
    }
    printf("\n");

    // Cleanup
    cudaEventDestroy(t0);
    cudaEventDestroy(t1);
    cudaFree(lw.d_wq); cudaFree(lw.d_wk); cudaFree(lw.d_wv); cudaFree(lw.d_wo);
    cudaFree(lw.d_wgate); cudaFree(lw.d_wup); cudaFree(lw.d_wdown);
    cudaFree(d_X); cudaFree(d_Y); cudaFree(d_tmp);

    return 0;
}

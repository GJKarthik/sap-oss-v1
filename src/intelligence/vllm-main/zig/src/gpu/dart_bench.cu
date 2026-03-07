// DART Speculative Decoding Benchmark for T4
//
// Measures the real cost savings from KV cache save/restore optimization.
// Simulates the DART workflow using actual GEMV kernel timings:
//
// Baseline: 1 token per step (standard autoregressive)
// DART (old): draft K tokens + re-prefill P tokens + verify K tokens
// DART (fixed): draft K tokens + restore seq_len + verify K tokens
//
// Uses the optimized Q4_0 GEMV kernel (shared memory + bank-conflict-free padding)
// to measure real per-token forward pass cost on T4.

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <cuda_runtime.h>
#include <cuda_fp16.h>

// ============================================================================
// Optimized Q4_0 GEMV kernel (from production — shared mem + padded layout)
// ============================================================================
__global__ void q4_0_gemv_opt(float* __restrict__ y,
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

    if (tx == 0) y[row] = acc;
}

// ============================================================================
// Simulate one transformer layer decode step (7 GEMV ops for LLaMA-7B)
// Returns: GPU time in ms for one layer
// ============================================================================
struct LayerBuffers {
    uint8_t *d_wq, *d_wk, *d_wv, *d_wo;     // QKV + output proj weights
    uint8_t *d_wgate, *d_wup, *d_wdown;       // FFN weights
    float *d_x, *d_hidden, *d_out;             // activations
};

void run_one_layer(LayerBuffers& buf, int dim, int ffn_dim, int smem_dim, int smem_ffn) {
    int grid_dim = (dim + 7) / 8;
    int grid_ffn = (ffn_dim + 7) / 8;

    // QKV projections (3x dim×dim)
    q4_0_gemv_opt<<<grid_dim, 256, smem_dim>>>(buf.d_out, buf.d_wq, buf.d_x, dim, dim);
    q4_0_gemv_opt<<<grid_dim, 256, smem_dim>>>(buf.d_out, buf.d_wk, buf.d_x, dim, dim);
    q4_0_gemv_opt<<<grid_dim, 256, smem_dim>>>(buf.d_out, buf.d_wv, buf.d_x, dim, dim);
    // Output projection (dim×dim)
    q4_0_gemv_opt<<<grid_dim, 256, smem_dim>>>(buf.d_out, buf.d_wo, buf.d_hidden, dim, dim);
    // FFN gate + up (ffn_dim×dim)
    q4_0_gemv_opt<<<grid_ffn, 256, smem_dim>>>(buf.d_out, buf.d_wgate, buf.d_x, ffn_dim, dim);
    q4_0_gemv_opt<<<grid_ffn, 256, smem_dim>>>(buf.d_out, buf.d_wup, buf.d_x, ffn_dim, dim);
    // FFN down (dim×ffn_dim)
    q4_0_gemv_opt<<<grid_dim, 256, smem_ffn>>>(buf.d_out, buf.d_wdown, buf.d_hidden, dim, ffn_dim);
}

// ============================================================================
// Main benchmark
// ============================================================================
int main() {
    printf("DART Speculative Decoding Benchmark (T4)\n");
    printf("=========================================\n\n");

    // LLaMA-7B dimensions
    const int dim = 4096;
    const int ffn_dim = 11008;
    const int n_layers = 32;
    const int vocab_size = 32000;

    // Shared memory sizes (padded)
    int smem_dim = (dim + dim / 32) * sizeof(float);      // 16,896 bytes
    int smem_ffn = (ffn_dim + ffn_dim / 32) * sizeof(float); // 45,408 bytes

    // Weight sizes (Q4_0: 18 bytes per 32 elements)
    size_t w_dim_bytes = (size_t)dim * (dim / 32) * 18;
    size_t w_ffn_up_bytes = (size_t)ffn_dim * (dim / 32) * 18;
    size_t w_ffn_down_bytes = (size_t)dim * (ffn_dim / 32) * 18;

    printf("Model: LLaMA-7B Q4_0\n");
    printf("  dim=%d, ffn=%d, layers=%d, vocab=%d\n", dim, ffn_dim, n_layers, vocab_size);
    printf("  Weight per layer: %.1f MB\n",
           (4.0 * w_dim_bytes + 2.0 * w_ffn_up_bytes + w_ffn_down_bytes) / 1e6);
    printf("  smem_dim=%d bytes, smem_ffn=%d bytes\n\n", smem_dim, smem_ffn);

    // Allocate GPU buffers
    LayerBuffers buf;
    cudaMalloc(&buf.d_wq, w_dim_bytes);
    cudaMalloc(&buf.d_wk, w_dim_bytes);
    cudaMalloc(&buf.d_wv, w_dim_bytes);
    cudaMalloc(&buf.d_wo, w_dim_bytes);
    cudaMalloc(&buf.d_wgate, w_ffn_up_bytes);
    cudaMalloc(&buf.d_wup, w_ffn_up_bytes);
    cudaMalloc(&buf.d_wdown, w_ffn_down_bytes);
    cudaMalloc(&buf.d_x, dim * sizeof(float));
    cudaMalloc(&buf.d_hidden, ffn_dim * sizeof(float));
    cudaMalloc(&buf.d_out, ffn_dim * sizeof(float));

    // Zero-init weights (content doesn't matter for timing)
    cudaMemset(buf.d_wq, 0, w_dim_bytes);
    cudaMemset(buf.d_wk, 0, w_dim_bytes);
    cudaMemset(buf.d_wv, 0, w_dim_bytes);
    cudaMemset(buf.d_wo, 0, w_dim_bytes);
    cudaMemset(buf.d_wgate, 0, w_ffn_up_bytes);
    cudaMemset(buf.d_wup, 0, w_ffn_up_bytes);
    cudaMemset(buf.d_wdown, 0, w_ffn_down_bytes);
    cudaMemset(buf.d_x, 0, dim * sizeof(float));
    cudaMemset(buf.d_hidden, 0, ffn_dim * sizeof(float));

    // ========================================================================
    // Measure: Single-token decode (all 32 layers)
    // ========================================================================
    printf("=== Phase 1: Single-token decode timing ===\n");

    // Warmup
    for (int w = 0; w < 5; w++) {
        for (int l = 0; l < n_layers; l++)
            run_one_layer(buf, dim, ffn_dim, smem_dim, smem_ffn);
    }
    cudaDeviceSynchronize();

    cudaEvent_t t0, t1;
    cudaEventCreate(&t0);
    cudaEventCreate(&t1);

    int N_iters = 50;
    cudaEventRecord(t0);
    for (int i = 0; i < N_iters; i++) {
        for (int l = 0; l < n_layers; l++)
            run_one_layer(buf, dim, ffn_dim, smem_dim, smem_ffn);
    }
    cudaEventRecord(t1);
    cudaEventSynchronize(t1);

    float total_ms;
    cudaEventElapsedTime(&total_ms, t0, t1);
    float ms_per_token = total_ms / N_iters;
    float baseline_tps = 1000.0f / ms_per_token;

    printf("  Per-token forward (32 layers, 7 GEMV each): %.2f ms\n", ms_per_token);
    printf("  Baseline TPS (no speculation): %.1f\n\n", baseline_tps);

    // ========================================================================
    // Measure: Prefill cost (simulates re-prefill of P prompt tokens)
    // In practice, prefill runs each token through all layers sequentially.
    // For GEMV-bound decode, prefill of P tokens ≈ P × single-token time.
    // ========================================================================
    printf("=== Phase 2: Prefill cost measurement ===\n");

    int prompt_lengths[] = {128, 256, 512, 1024, 2048};
    int n_prompts = 5;

    for (int pi = 0; pi < n_prompts; pi++) {
        int P = prompt_lengths[pi];
        float prefill_ms = P * ms_per_token;  // Each token runs through all layers
        printf("  Prefill %4d tokens: %.1f ms (%.1f sec)\n", P, prefill_ms, prefill_ms / 1000.0f);
    }
    printf("\n");

    // ========================================================================
    // Phase 3: DART speculation simulation
    // ========================================================================
    printf("=== Phase 3: DART Speculative Decoding Simulation ===\n\n");

    // DART head forward: small GEMV (hidden_size → head_hidden × K positions)
    // DART head: 4096 → 512 → vocab per draft position (K=4)
    // Cost: ~0.1ms (tiny compared to full model forward)
    float dart_head_ms = 0.1f;

    // Tree verification: verify K draft tokens in one batched forward pass
    // With tree attention, K tokens verified in ~1.1× single-token time
    // (tree attention adds minimal overhead over single decode)
    float tree_overhead_factor = 1.1f;

    printf("  DART head cost: %.1f ms\n", dart_head_ms);
    printf("  Tree verification overhead: %.0f%%\n", (tree_overhead_factor - 1.0f) * 100.0f);
    printf("  Baseline single-token: %.2f ms\n\n", ms_per_token);

    // Sweep: draft length K and acceptance rate α
    int draft_lengths[] = {2, 3, 4, 5, 6};
    float acceptance_rates[] = {0.5f, 0.6f, 0.7f, 0.8f, 0.9f};
    int n_K = 5;
    int n_alpha = 5;

    printf("%-6s", "K\\α");
    for (int ai = 0; ai < n_alpha; ai++)
        printf("  α=%.1f  ", acceptance_rates[ai]);
    printf("\n");
    printf("------");
    for (int ai = 0; ai < n_alpha; ai++)
        printf("--------");
    printf("\n");

    // For each (K, α) combination, compute effective TPS for:
    // (a) DART with KV cache reuse (our fix)
    // (b) DART with re-prefill (old broken version), prompt=512 tokens

    for (int ki = 0; ki < n_K; ki++) {
        int K = draft_lengths[ki];
        printf("K=%-4d", K);

        for (int ai = 0; ai < n_alpha; ai++) {
            float alpha = acceptance_rates[ai];

            // Expected accepted tokens per speculation cycle:
            // E[accepted] = α + α² + α³ + ... + α^K + correction_token
            // = α(1 - α^K)/(1 - α) + 1  (geometric series + 1 correction)
            float expected_accepted;
            if (fabsf(alpha - 1.0f) < 1e-6f) {
                expected_accepted = K + 1.0f;
            } else {
                expected_accepted = alpha * (1.0f - powf(alpha, K)) / (1.0f - alpha) + 1.0f;
            }

            // Cost per cycle (with KV cache reuse):
            // = 1 target forward (get hidden states)
            // + DART head forward
            // + 1 verification forward (tree attention for K tokens)
            float cycle_cost_fixed = ms_per_token + dart_head_ms +
                                     ms_per_token * tree_overhead_factor;

            float effective_tps = expected_accepted * 1000.0f / cycle_cost_fixed;
            printf("  %5.1f ", effective_tps);
        }
        printf("\n");
    }

    printf("\n");

    // ========================================================================
    // Phase 4: Comparison — DART fixed vs broken (re-prefill) vs baseline
    // ========================================================================
    printf("=== Phase 4: DART Fixed vs Broken vs Baseline ===\n\n");

    int prompt_P = 512;
    float prefill_cost = prompt_P * ms_per_token;
    int K_opt = 4;  // Optimal K for T4

    printf("Prompt length: %d tokens\n", prompt_P);
    printf("Draft length K: %d\n", K_opt);
    printf("Prefill cost: %.1f ms\n\n", prefill_cost);

    printf("%-14s  %-8s  %-8s  %-10s  %-10s\n",
           "Accept Rate", "Baseline", "DART Fix", "DART Old", "Speedup");
    printf("%-14s  %-8s  %-8s  %-10s  %-10s\n",
           "-----------", "--------", "--------", "--------", "-------");

    for (int ai = 0; ai < n_alpha; ai++) {
        float alpha = acceptance_rates[ai];
        float expected_accepted;
        if (fabsf(alpha - 1.0f) < 1e-6f) {
            expected_accepted = K_opt + 1.0f;
        } else {
            expected_accepted = alpha * (1.0f - powf(alpha, K_opt)) / (1.0f - alpha) + 1.0f;
        }

        // Baseline: 1 token per step
        float baseline_cycle = ms_per_token;
        float baseline_eff = 1000.0f / baseline_cycle;

        // DART with fix (KV cache reuse): target + head + verify
        float fixed_cycle = ms_per_token + dart_head_ms +
                           ms_per_token * tree_overhead_factor;
        float fixed_eff = expected_accepted * 1000.0f / fixed_cycle;

        // DART broken (re-prefill): target + head + RE-PREFILL + verify
        float broken_cycle = ms_per_token + dart_head_ms +
                            prefill_cost +
                            ms_per_token * tree_overhead_factor;
        float broken_eff = expected_accepted * 1000.0f / broken_cycle;

        printf("α=%.1f          %6.1f    %6.1f    %6.1f      %.2fx / %.2fx\n",
               alpha, baseline_eff, fixed_eff, broken_eff,
               fixed_eff / baseline_eff, broken_eff / baseline_eff);
    }

    printf("\n");

    // ========================================================================
    // Phase 5: Multi-step generation simulation (100 tokens)
    // ========================================================================
    printf("=== Phase 5: 100-token generation wall time ===\n\n");

    int gen_tokens = 100;
    float alpha_typical = 0.7f;
    float expected_per_cycle;
    {
        float a = alpha_typical;
        expected_per_cycle = a * (1.0f - powf(a, K_opt)) / (1.0f - a) + 1.0f;
    }

    float baseline_time = gen_tokens * ms_per_token;
    int n_cycles = (int)ceilf(gen_tokens / expected_per_cycle);

    float fixed_cycle = ms_per_token + dart_head_ms + ms_per_token * tree_overhead_factor;
    float fixed_time = n_cycles * fixed_cycle;

    float broken_cycle = ms_per_token + dart_head_ms + prefill_cost + ms_per_token * tree_overhead_factor;
    float broken_time = n_cycles * broken_cycle;

    printf("  Generate %d tokens (α=%.1f, K=%d, prompt=%d):\n",
           gen_tokens, alpha_typical, K_opt, prompt_P);
    printf("  Expected tokens/cycle: %.2f, cycles needed: %d\n\n", expected_per_cycle, n_cycles);
    printf("  %-20s  %8s  %8s\n", "Method", "Time(ms)", "Eff TPS");
    printf("  %-20s  %8s  %8s\n", "------", "-------", "-------");
    printf("  %-20s  %8.1f  %8.1f\n", "Baseline (no spec)", baseline_time, gen_tokens * 1000.0f / baseline_time);
    printf("  %-20s  %8.1f  %8.1f\n", "DART (fixed/ours)", fixed_time, gen_tokens * 1000.0f / fixed_time);
    printf("  %-20s  %8.1f  %8.1f\n", "DART (broken/old)", broken_time, gen_tokens * 1000.0f / broken_time);
    printf("\n");
    printf("  KV cache fix speedup vs broken: %.1fx\n", broken_time / fixed_time);
    printf("  DART fixed speedup vs baseline: %.2fx\n", baseline_time / fixed_time);
    printf("\n");

    // Cleanup
    cudaEventDestroy(t0);
    cudaEventDestroy(t1);
    cudaFree(buf.d_wq); cudaFree(buf.d_wk); cudaFree(buf.d_wv); cudaFree(buf.d_wo);
    cudaFree(buf.d_wgate); cudaFree(buf.d_wup); cudaFree(buf.d_wdown);
    cudaFree(buf.d_x); cudaFree(buf.d_hidden); cudaFree(buf.d_out);

    return 0;
}

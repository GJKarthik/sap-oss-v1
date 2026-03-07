//! CUDA Forward Pass Benchmark — T4 Target
//!
//! Measures decode throughput (TPS) for:
//!   1. Normal forward pass (individual kernel launches)
//!   2. CUDA Graph replay (captured kernel graph)
//!
//! Usage:
//!   zig build bench-cuda -Dgpu=true
//!   ./zig-out/bin/cuda-bench [model_path]
//!
//! Expected on T4 with 7B Q4_0: ≥100 TPS at 1000 token context

const std = @import("std");
const cuda_fwd_mod = @import("cuda_forward");
const CudaForwardPass = cuda_fwd_mod.CudaForwardPass;
const CudaForwardConfig = cuda_fwd_mod.CudaForwardConfig;
const CudaBackend = cuda_fwd_mod.cuda_backend.CudaBackend;
const cuda = cuda_fwd_mod.cuda_bindings;
const GpuModelWeights = cuda_fwd_mod.cuda_weights.GpuModelWeights;
const GpuTensor = cuda_fwd_mod.cuda_weights.GpuTensor;
const GGMLType = cuda_fwd_mod.cuda_weights.GGMLType;

const log = std.log.scoped(.cuda_bench);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  CUDA Forward Pass Benchmark — T4 Target                    ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Target: ≥100 TPS decode at 1000 token context              ║\n", .{});
    std.debug.print("║  Model:  LLaMA-7B Q4_0 (3.6 GB VRAM)                       ║\n", .{});
    std.debug.print("║  GPU:    NVIDIA T4 (SM75, 16GB, 320 GB/s)                   ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // ========================================================================
    // Phase 1: Initialize CUDA backend
    // ========================================================================
    std.debug.print("[Phase 1] Initializing CUDA backend...\n", .{});

    var backend = try CudaBackend.init(allocator, .{
        .device_id = 0,
        .enable_int8 = true,
        .enable_flash_attention = true,
    });
    defer backend.deinit();

    if (!backend.isAvailable()) {
        std.debug.print("  ERROR: CUDA not available. Need T4 GPU with driver.\n", .{});
        return;
    }

    std.debug.print("  Device: {s}\n", .{backend.device_name});
    std.debug.print("  Compute: {}.{}\n", .{ backend.compute_capability.major, backend.compute_capability.minor });
    std.debug.print("  Stream:  {s}\n", .{if (backend.stream != null) "created" else "none"});
    std.debug.print("  Kernels: {} loaded\n", .{backend.loadedKernelCount()});

    // ========================================================================
    // Phase 2: Allocate GPU weights (synthetic — fill with random Q4_0 data)
    // ========================================================================
    std.debug.print("\n[Phase 2] Allocating GPU model weights (synthetic 7B Q4_0)...\n", .{});

    // LLaMA-7B dimensions
    const dim: u32 = 4096;
    const n_layers: u32 = 32;
    const n_heads: u32 = 32;
    const n_kv_heads: u32 = 8; // GQA
    const head_dim: u32 = dim / n_heads;
    const ff: u32 = 11008;
    const vocab: u32 = 32000;
    const max_seq: u32 = 4096;
    const kv_dim = n_kv_heads * head_dim;

    var gpu_weights = try GpuModelWeights.init(allocator, n_layers);
    defer gpu_weights.deinit();

    // Allocate token embedding [vocab × dim] as Q4_0
    gpu_weights.token_embedding = try GpuTensor.alloc(.q4_0, vocab, dim);
    gpu_weights.final_norm = try GpuTensor.alloc(.f32, 1, dim);
    gpu_weights.lm_head = try GpuTensor.alloc(.q4_0, vocab, dim);

    for (gpu_weights.layers) |*layer| {
        layer.attn_norm = try GpuTensor.alloc(.f32, 1, dim);
        layer.ffn_norm = try GpuTensor.alloc(.f32, 1, dim);
        layer.wq = try GpuTensor.alloc(.q4_0, n_heads * head_dim, dim);
        layer.wk = try GpuTensor.alloc(.q4_0, kv_dim, dim);
        layer.wv = try GpuTensor.alloc(.q4_0, kv_dim, dim);
        layer.wo = try GpuTensor.alloc(.q4_0, dim, n_heads * head_dim);
        layer.w_gate = try GpuTensor.alloc(.q4_0, ff, dim);
        layer.w_up = try GpuTensor.alloc(.q4_0, ff, dim);
        layer.w_down = try GpuTensor.alloc(.q4_0, dim, ff);
    }

    std.debug.print("  Weights VRAM: {} MB\n", .{gpu_weights.totalVramMB()});

    // ========================================================================
    // Phase 3: Create CUDA forward pass
    // ========================================================================
    std.debug.print("\n[Phase 3] Creating CUDA forward pass...\n", .{});

    var fwd = try CudaForwardPass.init(allocator, .{
        .dim = dim,
        .n_layers = n_layers,
        .n_heads = n_heads,
        .n_kv_heads = n_kv_heads,
        .n_ff = ff,
        .vocab_size = vocab,
        .max_seq_len = max_seq,
        .rope_freq_base = 10000.0,
        .weight_dtype = .q4_0,
    }, backend, gpu_weights);
    defer fwd.deinit();

    const vram = fwd.vramUsageMB();
    std.debug.print("  Total VRAM: {} MB (weights={} kv={} act={})\n", .{
        vram.total, vram.weights, vram.kv_cache, vram.activations,
    });

    // ========================================================================
    // Phase 4: Warmup — prefill 1000 tokens
    // ========================================================================
    std.debug.print("\n[Phase 4] Prefill warmup (1000 tokens)...\n", .{});

    const prefill_len: usize = 1000;
    const prefill_start = std.time.nanoTimestamp();
    for (0..prefill_len) |i| {
        const token: u32 = @intCast(i % vocab);
        _ = try fwd.forward(token, i);
    }
    try backend.syncGpu();
    const prefill_end = std.time.nanoTimestamp();
    const prefill_ms = @as(f64, @floatFromInt(prefill_end - prefill_start)) / 1e6;
    const prefill_tps = @as(f64, @floatFromInt(prefill_len)) / (prefill_ms / 1000.0);
    std.debug.print("  Prefill: {d:.1} ms ({d:.0} tokens/sec)\n", .{ prefill_ms, prefill_tps });

    // ========================================================================
    // Phase 5: Decode benchmark — 100 tokens (normal kernel dispatch)
    // ========================================================================
    std.debug.print("\n[Phase 5] Decode benchmark (normal dispatch, 100 tokens)...\n", .{});

    const decode_count: usize = 100;
    const decode_start = std.time.nanoTimestamp();
    for (0..decode_count) |i| {
        const pos = prefill_len + i;
        const token: u32 = @intCast(pos % vocab);
        _ = try fwd.forward(token, pos);
    }
    try backend.syncGpu();
    const decode_end = std.time.nanoTimestamp();
    const decode_ms = @as(f64, @floatFromInt(decode_end - decode_start)) / 1e6;
    const decode_tps = @as(f64, @floatFromInt(decode_count)) / (decode_ms / 1000.0);

    std.debug.print("  Decode: {d:.1} ms for {} tokens\n", .{ decode_ms, decode_count });
    std.debug.print("  *** Normal TPS: {d:.1} ***\n", .{decode_tps});

    // ========================================================================
    // Phase 6: Decode benchmark — CUDA Graph replay
    // ========================================================================
    std.debug.print("\n[Phase 6] Decode benchmark (CUDA Graph replay, 100 tokens)...\n", .{});

    if (backend.stream != null) {
        // Capture one decode step as a graph
        const graph_pos = prefill_len + decode_count;
        const graph_token: u32 = @intCast(graph_pos % vocab);
        _ = try fwd.captureGraph(graph_token, graph_pos);

        if (backend.hasGraph()) {
            const graph_start = std.time.nanoTimestamp();
            for (0..decode_count) |_| {
                _ = try fwd.forwardGraphed();
            }
            try backend.syncStream();
            const graph_end = std.time.nanoTimestamp();
            const graph_ms = @as(f64, @floatFromInt(graph_end - graph_start)) / 1e6;
            const graph_tps = @as(f64, @floatFromInt(decode_count)) / (graph_ms / 1000.0);

            std.debug.print("  Graph decode: {d:.1} ms for {} tokens\n", .{ graph_ms, decode_count });
            std.debug.print("  *** Graph TPS: {d:.1} ***\n", .{graph_tps});

            const speedup = graph_tps / decode_tps;
            std.debug.print("  Speedup: {d:.2}x\n", .{speedup});
        } else {
            std.debug.print("  Graph capture failed (stream may not support capture)\n", .{});
        }
    } else {
        std.debug.print("  Skipped — no CUDA stream available\n", .{});
    }

    // ========================================================================
    // Phase 7: Profiled decode — timing breakdown
    // ========================================================================
    std.debug.print("\n[Phase 7] Profiled decode (10 tokens, per-phase timing)...\n", .{});
    {
        fwd.reset();
        // Quick prefill to position 1000
        for (0..prefill_len) |i| {
            _ = try fwd.forward(@intCast(i % vocab), i);
        }

        const prof_count: usize = 10;
        var sum_gemv: i128 = 0;
        var sum_attn: i128 = 0;
        var sum_other: i128 = 0;
        var sum_total: i128 = 0;

        for (0..prof_count) |i| {
            const pos = prefill_len + i;
            const token: u32 = @intCast(pos % vocab);
            const timing = try fwd.forwardProfiled(token, pos);
            sum_gemv += timing[0];
            sum_attn += timing[1];
            sum_other += timing[2];
            sum_total += timing[3];
        }

        const ms_gemv = @as(f64, @floatFromInt(sum_gemv)) / 1e6 / @as(f64, @floatFromInt(prof_count));
        const ms_attn = @as(f64, @floatFromInt(sum_attn)) / 1e6 / @as(f64, @floatFromInt(prof_count));
        const ms_other = @as(f64, @floatFromInt(sum_other)) / 1e6 / @as(f64, @floatFromInt(prof_count));
        const ms_total = @as(f64, @floatFromInt(sum_total)) / 1e6 / @as(f64, @floatFromInt(prof_count));

        std.debug.print("  Per-token breakdown (avg of {} tokens):\n", .{prof_count});
        std.debug.print("    GEMV (q4_0):  {d:>8.2} ms ({d:>5.1}%%)\n", .{ ms_gemv, ms_gemv / ms_total * 100.0 });
        std.debug.print("    Attention:    {d:>8.2} ms ({d:>5.1}%%)\n", .{ ms_attn, ms_attn / ms_total * 100.0 });
        std.debug.print("    Other:        {d:>8.2} ms ({d:>5.1}%%)\n", .{ ms_other, ms_other / ms_total * 100.0 });
        std.debug.print("    Total:        {d:>8.2} ms\n", .{ms_total});
        std.debug.print("    Profiled TPS: {d:>8.1}\n", .{1000.0 / ms_total});
        // Weight bandwidth estimate
        const weight_gb: f64 = 3.33; // ~3.33 GB for 7B Q4_0
        const bw_gbps = weight_gb / (ms_gemv / 1000.0);
        std.debug.print("    GEMV BW:      {d:>8.1} GB/s (of 320 GB/s peak)\n", .{bw_gbps});
    }

    // ========================================================================
    // Summary
    // ========================================================================
    std.debug.print("\n╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Results Summary                                             ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Prefill TPS:    {d:>8.1}                                    ║\n", .{prefill_tps});
    std.debug.print("║  Normal TPS:     {d:>8.1}                                    ║\n", .{decode_tps});
    std.debug.print("║  Target TPS:     {d:>8.1}                                    ║\n", .{@as(f64, 100.0)});
    std.debug.print("║  Status:         {s}                               ║\n", .{
        if (decode_tps >= 100.0) "✓ PASS " else "✗ BELOW",
    });
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});

    const stats = backend.getStats();
    std.debug.print("\n  Kernel dispatches: {}\n", .{stats.kernel_dispatches});
    std.debug.print("  Total elements:    {}\n", .{stats.total_elements});
}

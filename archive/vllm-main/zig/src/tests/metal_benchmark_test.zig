///! Metal Performance Benchmark
///!
///! Measures tokens/second for the Zig inference pipeline on Apple Silicon.
///! Tests three scenarios:
///!   1. Decode throughput: single-token forward() calls (the 50 tok/s bottleneck)
///!   2. Prefill throughput: forwardBatch() vs sequential forward()
///!   3. End-to-end generate throughput
///!
///! The 50 tok/s issue was caused by:
///!   - CPU-only scalar matmul in forward() (Fix 2: Accelerate BLAS)
///!   - Per-token logits during prefill (Fix 5: forwardBatch)
///!   - O(N²) detokenization for stop detection (Fix 6: token ID check)
///!
///! Run with: zig build test-slow 2>&1 | grep -A2 "BENCHMARK"

const std = @import("std");
const builtin = @import("builtin");
const math = std.math;
const llama = @import("llama");

const Model = llama.Model;
const ModelConfig = llama.ModelConfig;
const KVCache = llama.KVCache;
const Sampler = llama.Sampler;
const InferenceEngine = llama.InferenceEngine;

// ============================================================================
// Benchmark configurations — sized to stress the hot paths
// ============================================================================

// "Small" config: similar to TinyLlama / LLaMA-1B proportions
const BENCH_SMALL = ModelConfig{
    .n_layers = 4,
    .n_heads = 8,
    .n_kv_heads = 4, // GQA
    .n_embd = 128,
    .n_ff = 256,
    .vocab_size = 256,
    .context_length = 512,
};

// "Medium" config: closer to real-world dim proportions
const BENCH_MEDIUM = ModelConfig{
    .n_layers = 8,
    .n_heads = 8,
    .n_kv_heads = 4, // GQA
    .n_embd = 256,
    .n_ff = 512,
    .vocab_size = 512,
    .context_length = 512,
};

// "Large" config: stresses matmul paths
const BENCH_LARGE = ModelConfig{
    .n_layers = 12,
    .n_heads = 16,
    .n_kv_heads = 4, // GQA
    .n_embd = 512,
    .n_ff = 1024,
    .vocab_size = 1024,
    .context_length = 512,
};

fn nsToMs(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

// ============================================================================
// Benchmark 1: Decode throughput (single-token forward)
// This is the exact path that was bottlenecked at 50 tok/s
// ============================================================================

test "BENCHMARK: decode tok/s (single-token forward, small model)" {
    const allocator = std.testing.allocator;
    const config = BENCH_SMALL;
    const n_tokens: usize = 100;

    const model = try Model.load(allocator, config);
    defer model.deinit();

    var cache = try KVCache.init(allocator, config);
    defer cache.deinit(std.testing.allocator);

    // Warmup
    _ = model.forward(1, 0, &cache);

    // Reset cache
    cache.seq_len = 0;

    // Benchmark: n_tokens sequential forward() calls
    const start = std.time.nanoTimestamp();
    for (0..n_tokens) |pos| {
        const tok: u32 = @intCast((pos % (config.vocab_size - 1)) + 1);
        const logits = model.forward(tok, pos, &cache);
        // Prevent dead-code elimination
        std.mem.doNotOptimizeAway(logits.ptr);
    }
    const elapsed_ns = std.time.nanoTimestamp() - start;

    const elapsed_ms = nsToMs(elapsed_ns);
    const tok_per_sec = @as(f64, @floatFromInt(n_tokens)) / (elapsed_ms / 1000.0);

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  BENCHMARK: Decode (small, dim={d}, layers={d})       ║\n", .{ config.n_embd, config.n_layers });
    std.debug.print("╠══════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Tokens:     {d:>6}                                   ║\n", .{n_tokens});
    std.debug.print("║  Time:       {d:>9.1} ms                             ║\n", .{elapsed_ms});
    std.debug.print("║  Throughput: {d:>9.1} tok/s                          ║\n", .{tok_per_sec});
    std.debug.print("╚══════════════════════════════════════════════════════╝\n", .{});

    // The old bottleneck was ~50 tok/s. With Accelerate BLAS on small model,
    // we expect significantly higher throughput.
    try std.testing.expect(tok_per_sec > 10.0); // sanity: at least 10 tok/s
}

test "BENCHMARK: decode tok/s (single-token forward, medium model)" {
    const allocator = std.testing.allocator;
    const config = BENCH_MEDIUM;
    const n_tokens: usize = 50;

    const model = try Model.load(allocator, config);
    defer model.deinit();

    var cache = try KVCache.init(allocator, config);
    defer cache.deinit(std.testing.allocator);

    _ = model.forward(1, 0, &cache);
    cache.seq_len = 0;

    const start = std.time.nanoTimestamp();
    for (0..n_tokens) |pos| {
        const tok: u32 = @intCast((pos % (config.vocab_size - 1)) + 1);
        const logits = model.forward(tok, pos, &cache);
        std.mem.doNotOptimizeAway(logits.ptr);
    }
    const elapsed_ns = std.time.nanoTimestamp() - start;

    const elapsed_ms = nsToMs(elapsed_ns);
    const tok_per_sec = @as(f64, @floatFromInt(n_tokens)) / (elapsed_ms / 1000.0);

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  BENCHMARK: Decode (medium, dim={d}, layers={d})      ║\n", .{ config.n_embd, config.n_layers });
    std.debug.print("╠══════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Tokens:     {d:>6}                                   ║\n", .{n_tokens});
    std.debug.print("║  Time:       {d:>9.1} ms                             ║\n", .{elapsed_ms});
    std.debug.print("║  Throughput: {d:>9.1} tok/s                          ║\n", .{tok_per_sec});
    std.debug.print("╚══════════════════════════════════════════════════════╝\n", .{});

    try std.testing.expect(tok_per_sec > 5.0);
}

test "BENCHMARK: decode tok/s (single-token forward, large model)" {
    const allocator = std.testing.allocator;
    const config = BENCH_LARGE;
    const n_tokens: usize = 30;

    const model = try Model.load(allocator, config);
    defer model.deinit();

    var cache = try KVCache.init(allocator, config);
    defer cache.deinit(std.testing.allocator);

    _ = model.forward(1, 0, &cache);
    cache.seq_len = 0;

    const start = std.time.nanoTimestamp();
    for (0..n_tokens) |pos| {
        const tok: u32 = @intCast((pos % (config.vocab_size - 1)) + 1);
        const logits = model.forward(tok, pos, &cache);
        std.mem.doNotOptimizeAway(logits.ptr);
    }
    const elapsed_ns = std.time.nanoTimestamp() - start;

    const elapsed_ms = nsToMs(elapsed_ns);
    const tok_per_sec = @as(f64, @floatFromInt(n_tokens)) / (elapsed_ms / 1000.0);

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  BENCHMARK: Decode (large, dim={d}, layers={d})      ║\n", .{ config.n_embd, config.n_layers });
    std.debug.print("╠══════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Tokens:     {d:>6}                                   ║\n", .{n_tokens});
    std.debug.print("║  Time:       {d:>9.1} ms                             ║\n", .{elapsed_ms});
    std.debug.print("║  Throughput: {d:>9.1} tok/s                          ║\n", .{tok_per_sec});
    std.debug.print("╚══════════════════════════════════════════════════════╝\n", .{});

    try std.testing.expect(tok_per_sec > 1.0);
}

// ============================================================================
// Benchmark 2: Prefill — forwardBatch() vs sequential forward()
// Measures the speedup from skipping logits on non-final tokens
// ============================================================================

test "BENCHMARK: prefill forwardBatch vs sequential (medium model)" {
    const allocator = std.testing.allocator;
    const config = BENCH_MEDIUM;
    const prompt_len: usize = 64;

    const model = try Model.load(allocator, config);
    defer model.deinit();

    // Build prompt
    var prompt: [64]u32 = undefined;
    for (0..prompt_len) |i| prompt[i] = @intCast((i % (config.vocab_size - 1)) + 1);

    // --- Sequential forward (old path) ---
    var cache_seq = try KVCache.init(allocator, config);
    defer cache_seq.deinit(std.testing.allocator);

    const start_seq = std.time.nanoTimestamp();
    for (prompt[0..prompt_len], 0..) |tok, pos| {
        _ = model.forward(tok, pos, &cache_seq);
    }
    const seq_ns = std.time.nanoTimestamp() - start_seq;

    // --- Batched forward (new path) ---
    var cache_batch = try KVCache.init(allocator, config);
    defer cache_batch.deinit(std.testing.allocator);

    const start_batch = std.time.nanoTimestamp();
    _ = model.forwardBatch(prompt[0..prompt_len], &cache_batch);
    const batch_ns = std.time.nanoTimestamp() - start_batch;

    const seq_ms = nsToMs(seq_ns);
    const batch_ms = nsToMs(batch_ns);
    const seq_tps = @as(f64, @floatFromInt(prompt_len)) / (seq_ms / 1000.0);
    const batch_tps = @as(f64, @floatFromInt(prompt_len)) / (batch_ms / 1000.0);
    const speedup = seq_ms / batch_ms;

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  BENCHMARK: Prefill (medium, {d} tokens)              ║\n", .{prompt_len});
    std.debug.print("╠══════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Sequential:  {d:>8.1} ms  ({d:>7.0} tok/s)          ║\n", .{ seq_ms, seq_tps });
    std.debug.print("║  Batched:     {d:>8.1} ms  ({d:>7.0} tok/s)          ║\n", .{ batch_ms, batch_tps });
    std.debug.print("║  Speedup:     {d:>8.2}x                              ║\n", .{speedup});
    std.debug.print("╚══════════════════════════════════════════════════════╝\n", .{});

    // This is a benchmark, not the correctness gate for `forwardBatch`.
    // Exact speed ratios are noisy in Debug builds and under shared CI load,
    // so only enforce a coarse sanity bound there. Functional equivalence is
    // already covered by perf_regression_test.zig.
    const max_overhead = switch (builtin.mode) {
        .Debug => 2.0,
        else => 1.15,
    };
    try std.testing.expect(batch_ms <= seq_ms * max_overhead);
}

// ============================================================================
// Benchmark 3: End-to-end generate throughput
// ============================================================================

test "BENCHMARK: end-to-end generate tok/s (medium model)" {
    const allocator = std.testing.allocator;
    const config = BENCH_MEDIUM;
    const max_gen_tokens: usize = 32;

    const model = try Model.load(allocator, config);
    defer model.deinit();

    const sampler = try Sampler.init(allocator, .{ .temperature = 0.0 });
    defer sampler.deinit();

    const engine = try InferenceEngine.init(allocator, model, sampler);
    defer engine.deinit();

    const prompt = [_]u32{ 1, 5, 10, 20, 30 };

    const start = std.time.nanoTimestamp();
    const output = try engine.generate(&prompt, max_gen_tokens);
    defer allocator.free(output);
    const elapsed_ns = std.time.nanoTimestamp() - start;

    const elapsed_ms = nsToMs(elapsed_ns);
    const total_tokens = output.len + prompt.len;
    const gen_tokens = output.len;
    const tok_per_sec = @as(f64, @floatFromInt(gen_tokens)) / (elapsed_ms / 1000.0);

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  BENCHMARK: End-to-End Generate (medium)              ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Prompt:      {d:>5} tokens                           ║\n", .{prompt.len});
    std.debug.print("║  Generated:   {d:>5} tokens                           ║\n", .{gen_tokens});
    std.debug.print("║  Total:       {d:>5} tokens                           ║\n", .{total_tokens});
    std.debug.print("║  Time:        {d:>8.1} ms                             ║\n", .{elapsed_ms});
    std.debug.print("║  Decode rate: {d:>8.1} tok/s                          ║\n", .{tok_per_sec});
    std.debug.print("╚══════════════════════════════════════════════════════╝\n", .{});

    try std.testing.expect(tok_per_sec > 1.0);
}

// ============================================================================
// Benchmark 4: Attention scaling — tok/s at different sequence positions
// Measures how throughput degrades as KV cache fills
// ============================================================================

test "BENCHMARK: attention scaling across sequence positions (medium)" {
    const allocator = std.testing.allocator;
    const config = BENCH_MEDIUM;

    const model = try Model.load(allocator, config);
    defer model.deinit();

    var cache = try KVCache.init(allocator, config);
    defer cache.deinit(std.testing.allocator);

    // Measure tok/s at different positions in the sequence
    const checkpoints = [_]usize{ 0, 16, 32, 64, 128 };
    var times: [checkpoints.len]f64 = undefined;

    // Fill cache up to max checkpoint
    var pos: usize = 0;
    var checkpoint_idx: usize = 0;

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  BENCHMARK: Attention Scaling (medium, dim={d})       ║\n", .{config.n_embd});
    std.debug.print("╠══════════════════════════════════════════════════════╣\n", .{});

    while (checkpoint_idx < checkpoints.len) : (checkpoint_idx += 1) {
        const target_pos = checkpoints[checkpoint_idx];

        // Fill cache up to target position
        while (pos < target_pos) : (pos += 1) {
            const tok: u32 = @intCast((pos % (config.vocab_size - 1)) + 1);
            _ = model.forward(tok, pos, &cache);
        }

        // Measure 10 forward passes at this position
        const n_measure: usize = 10;
        const start = std.time.nanoTimestamp();
        for (0..n_measure) |i| {
            const tok: u32 = @intCast(((pos + i) % (config.vocab_size - 1)) + 1);
            const logits = model.forward(tok, pos + i, &cache);
            std.mem.doNotOptimizeAway(logits.ptr);
        }
        const elapsed_ns = std.time.nanoTimestamp() - start;
        pos += n_measure;

        const elapsed_ms = nsToMs(elapsed_ns);
        const tps = @as(f64, @floatFromInt(n_measure)) / (elapsed_ms / 1000.0);
        times[checkpoint_idx] = tps;

        std.debug.print("║  pos={d:>4}: {d:>8.1} tok/s  ({d:>6.1} ms / {d} tok)    ║\n", .{ target_pos, tps, elapsed_ms, n_measure });
    }

    std.debug.print("╚══════════════════════════════════════════════════════╝\n", .{});

    // Throughput at pos=0 should be higher than at pos=128 (attention grows linearly)
    // But it shouldn't collapse — verify graceful degradation
    try std.testing.expect(times[checkpoints.len - 1] > times[0] * 0.05); // no worse than 20x slower
}

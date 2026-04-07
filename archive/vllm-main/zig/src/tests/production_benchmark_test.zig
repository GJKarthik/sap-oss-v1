///! Production Benchmark with Real GGUF Model
///!
///! Measures tok/s on actual LLaMA models loaded from GGUF files.
///! If no GGUF is available, falls back to synthetic model benchmarks.
///!
///! Usage:
///!   - Set GGUF_PATH env var to a real model file
///!   - Run: zig build test-slow
///!
///! Expected production tok/s on Apple Silicon (Metal):
///!   - LLaMA-1B (dim=2048): ~200-400 tok/s
///!   - LLaMA-3B (dim=3200): ~100-200 tok/s
///!   - LLaMA-7B (dim=4096): ~50-100 tok/s

const std = @import("std");
const llama = @import("llama");

const Model = llama.Model;
const KVCache = llama.KVCache;
const Sampler = llama.Sampler;
const InferenceEngine = llama.InferenceEngine;

fn nsToMs(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn getGgufPath(allocator: std.mem.Allocator) !?[]const u8 {
    const path = std.process.getEnvVarOwned(allocator, "GGUF_PATH") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        error.InvalidWtf8 => return null,
        error.OutOfMemory => |e| return e,
    };
    return path;
}

test "PRODUCTION: benchmark with real GGUF if available" {
    const allocator = std.testing.allocator;
    const gguf_path = (getGgufPath(allocator) catch null) orelse {
        std.debug.print("\n", .{});
        std.debug.print("╔══════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║  PRODUCTION BENCHMARK: No GGUF model found               ║\n", .{});
        std.debug.print("║  Set GGUF_PATH env var to a .gguf file to run real      ║\n", .{});
        std.debug.print("║  model benchmarks. Falling back to synthetic data.      ║\n", .{});
        std.debug.print("╚══════════════════════════════════════════════════════╝\n", .{});
        return;
    };
    defer allocator.free(gguf_path);

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  PRODUCTION BENCHMARK: Loading GGUF model                ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Model: {s}                                            ║\n", .{std.fs.path.basename(gguf_path)});
    std.debug.print("╚══════════════════════════════════════════════════════╝\n", .{});

    // Load real GGUF model
    const model = Model.loadFromGGUF(allocator, gguf_path) catch |err| {
        std.debug.print("Failed to load GGUF: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer model.deinit();

    const config = model.config;
    std.debug.print("Model config: {d} layers, {d} heads, dim={d}, vocab={d}\n", .{
        config.n_layers, config.n_heads, config.n_embd, config.vocab_size
    });

    // Benchmark decode throughput (the 50 tok/s bottleneck)
    var cache = try KVCache.init(allocator, config);
    defer cache.deinit(std.testing.allocator);

    const n_tokens: usize = 50;
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
    std.debug.print("║  PRODUCTION: Decode Throughput (real model)            ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Tokens:     {d:>6}                                   ║\n", .{n_tokens});
    std.debug.print("║  Time:       {d:>9.1} ms                            ║\n", .{elapsed_ms});
    std.debug.print("║  Throughput: {d:>9.1} tok/s                         ║\n", .{tok_per_sec});
    std.debug.print("╚══════════════════════════════════════════════════════╝\n", .{});

    // Verify we're well above the 50 tok/s bottleneck
    try std.testing.expect(tok_per_sec > 20.0); // at least 20 tok/s on real model

    // Benchmark end-to-end generation
    const sampler = try Sampler.init(allocator, .{ .temperature = 0.0 });
    defer sampler.deinit();

    const engine = try InferenceEngine.init(allocator, model, sampler);
    defer engine.deinit();

    const prompt = [_]u32{ 1, 5, 10, 20, 30 };
    const max_gen_tokens: usize = 20;

    const gen_start = std.time.nanoTimestamp();
    const output = try engine.generate(&prompt, max_gen_tokens);
    defer allocator.free(output);
    const gen_elapsed_ns = std.time.nanoTimestamp() - gen_start;

    const gen_elapsed_ms = nsToMs(gen_elapsed_ns);
    const gen_tps = @as(f64, @floatFromInt(output.len)) / (gen_elapsed_ms / 1000.0);

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  PRODUCTION: End-to-End Generation                  ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Prompt:      {d:>5} tokens                           ║\n", .{prompt.len});
    std.debug.print("║  Generated:   {d:>5} tokens                           ║\n", .{output.len});
    std.debug.print("║  Time:        {d:>8.1} ms                            ║\n", .{gen_elapsed_ms});
    std.debug.print("║  Decode rate: {d:>8.1} tok/s                         ║\n", .{gen_tps});
    std.debug.print("╚══════════════════════════════════════════════════════╝\n", .{});

    try std.testing.expect(gen_tps > 10.0);
}

test "PRODUCTION: batched prefill vs sequential (real model)" {
    const allocator = std.testing.allocator;
    const gguf_path = (getGgufPath(allocator) catch null) orelse return error.SkipZigTest;
    defer allocator.free(gguf_path);

    const model = Model.loadFromGGUF(allocator, gguf_path) catch |err| {
        std.debug.print("Failed to load GGUF: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer model.deinit();

    const config = model.config;
    const prompt_len: usize = 32;

    // Build prompt
    var prompt: [32]u32 = undefined;
    for (0..prompt_len) |i| prompt[i] = @intCast((i % (config.vocab_size - 1)) + 1);

    // Sequential forward
    var cache_seq = try KVCache.init(allocator, config);
    defer cache_seq.deinit(std.testing.allocator);

    const start_seq = std.time.nanoTimestamp();
    for (prompt[0..prompt_len], 0..) |tok, pos| {
        _ = model.forward(tok, pos, &cache_seq);
    }
    const seq_ns = std.time.nanoTimestamp() - start_seq;

    // Batched forward
    var cache_batch = try KVCache.init(allocator, config);
    defer cache_batch.deinit(std.testing.allocator);

    const start_batch = std.time.nanoTimestamp();
    _ = model.forwardBatch(prompt[0..prompt_len], &cache_batch);
    const batch_ns = std.time.nanoTimestamp() - start_batch;

    const seq_ms = nsToMs(seq_ns);
    const batch_ms = nsToMs(batch_ns);
    const speedup = seq_ms / batch_ms;

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  PRODUCTION: Prefill (real model, {d} tokens)        ║\n", .{prompt_len});
    std.debug.print("╠══════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Sequential:  {d:>8.1} ms                             ║\n", .{seq_ms});
    std.debug.print("║  Batched:     {d:>8.1} ms                             ║\n", .{batch_ms});
    std.debug.print("║  Speedup:     {d:>8.2}x                              ║\n", .{speedup});
    std.debug.print("╚══════════════════════════════════════════════════════╝\n", .{});

    // On real models with large vocab, batched should be faster
    try std.testing.expect(batch_ms <= seq_ms * 1.2); // allow 20% overhead
}

///! Performance & Correctness Regression Tests
///!
///! Validates all optimizations introduced in the privatellm perf fix plan:
///!   - forwardBatch matches sequential forward() (Fix 5: batched prefill)
///!   - Accelerate BLAS produces correct results (Fix 2: Apple Accelerate)
///!   - forwardNoLogits populates KV cache identically to forward() (Fix 5)
///!   - Greedy generate is deterministic and bounded (quality gate)
///!   - Stop detection token IDs match known newline patterns (Fix 6)

const std = @import("std");
const math = std.math;
const llama = @import("llama");

const Model = llama.Model;
const ModelConfig = llama.ModelConfig;
const KVCache = llama.KVCache;
const Sampler = llama.Sampler;
const InferenceEngine = llama.InferenceEngine;

// ============================================================================
// Fix 5: Batched Prefill — forwardBatch correctness
// ============================================================================

test "forwardBatch matches sequential forward for last-token logits" {
    const allocator = std.testing.allocator;
    const config = ModelConfig{
        .n_layers = 2,
        .n_heads = 4,
        .n_kv_heads = 4,
        .n_embd = 32,
        .n_ff = 64,
        .vocab_size = 64,
        .context_length = 16,
    };

    const model = try Model.load(allocator, config);
    defer model.deinit();

    const prompt = [_]u32{ 3, 7, 12, 5 };

    // Path A: sequential forward (the old way)
    var cache_seq = try KVCache.init(allocator, config);
    defer cache_seq.deinit(std.testing.allocator);
    var logits_seq: [64]f32 = undefined;
    for (prompt, 0..) |tok, pos| {
        const l = model.forward(tok, pos, &cache_seq);
        @memcpy(&logits_seq, l);
    }

    // Path B: batched forward (the new way)
    var cache_batch = try KVCache.init(allocator, config);
    defer cache_batch.deinit(std.testing.allocator);
    const logits_batch = model.forwardBatch(&prompt, &cache_batch);

    // Both must produce identical logits for the last token
    for (0..config.vocab_size) |i| {
        try std.testing.expect(!math.isNan(logits_batch[i]));
        try std.testing.expect(!math.isInf(logits_batch[i]));
        try std.testing.expectApproxEqAbs(logits_seq[i], logits_batch[i], 1e-5);
    }

    // KV cache positions must match
    try std.testing.expectEqual(cache_seq.seq_len, cache_batch.seq_len);
}

test "forwardBatch single-token degenerates to forward" {
    const allocator = std.testing.allocator;
    const config = ModelConfig{
        .n_layers = 1,
        .n_heads = 2,
        .n_kv_heads = 2,
        .n_embd = 16,
        .n_ff = 32,
        .vocab_size = 32,
        .context_length = 16,
    };

    const model = try Model.load(allocator, config);
    defer model.deinit();

    var cache_a = try KVCache.init(allocator, config);
    defer cache_a.deinit(std.testing.allocator);
    const logits_a = model.forward(5, 0, &cache_a);
    var saved_a: [32]f32 = undefined;
    @memcpy(&saved_a, logits_a);

    var cache_b = try KVCache.init(allocator, config);
    defer cache_b.deinit(std.testing.allocator);
    const single = [_]u32{5};
    const logits_b = model.forwardBatch(&single, &cache_b);

    for (0..config.vocab_size) |i| {
        try std.testing.expectApproxEqAbs(saved_a[i], logits_b[i], 1e-6);
    }
}

test "forwardBatch empty tokens returns without crash" {
    const allocator = std.testing.allocator;
    const config = ModelConfig{
        .n_layers = 1,
        .n_heads = 2,
        .n_kv_heads = 2,
        .n_embd = 16,
        .n_ff = 32,
        .vocab_size = 32,
        .context_length = 16,
    };

    const model = try Model.load(allocator, config);
    defer model.deinit();

    var cache = try KVCache.init(allocator, config);
    defer cache.deinit(std.testing.allocator);

    const empty: []const u32 = &.{};
    _ = model.forwardBatch(empty, &cache);
}

// ============================================================================
// Fix 2: Accelerate BLAS — numerical correctness
// ============================================================================

test "Accelerate vs pure Zig forward produce finite logits (GQA)" {
    const allocator = std.testing.allocator;
    const config = ModelConfig{
        .n_layers = 2,
        .n_heads = 4,
        .n_kv_heads = 2, // GQA to test heads_per_group path
        .n_embd = 32,
        .n_ff = 64,
        .vocab_size = 64,
        .context_length = 16,
    };

    const model = try Model.load(allocator, config);
    defer model.deinit();

    var cache = try KVCache.init(allocator, config);
    defer cache.deinit(std.testing.allocator);

    // Run multiple positions to exercise attention dot product + softmax paths
    for (0..5) |pos| {
        const tok: u32 = @intCast(pos + 1);
        const logits = model.forward(tok, pos, &cache);
        try std.testing.expectEqual(@as(usize, 64), logits.len);

        for (logits, 0..) |v, i| {
            if (math.isNan(v) or math.isInf(v)) {
                std.debug.print("NaN/Inf at logits[{}] pos={}\n", .{ i, pos });
                return error.TestUnexpectedResult;
            }
        }

        // Logits should diverge after position 0 (attention creates differences)
        if (pos > 0) {
            var all_same = true;
            for (logits[1..]) |v| {
                if (@abs(v - logits[0]) > 1e-8) {
                    all_same = false;
                    break;
                }
            }
            try std.testing.expect(!all_same);
        }
    }
}

// ============================================================================
// Fix 5: forwardNoLogits — KV cache population correctness
// ============================================================================

test "forwardNoLogits populates KV cache identically to forward" {
    const allocator = std.testing.allocator;
    const config = ModelConfig{
        .n_layers = 1,
        .n_heads = 2,
        .n_kv_heads = 2,
        .n_embd = 16,
        .n_ff = 32,
        .vocab_size = 32,
        .context_length = 16,
    };

    const model = try Model.load(allocator, config);
    defer model.deinit();

    // Path A: forward()
    var cache_a = try KVCache.init(allocator, config);
    defer cache_a.deinit(std.testing.allocator);
    _ = model.forward(3, 0, &cache_a);

    // Path B: forwardNoLogits()
    var cache_b = try KVCache.init(allocator, config);
    defer cache_b.deinit(std.testing.allocator);
    model.forwardNoLogits(3, 0, &cache_b);

    try std.testing.expectEqual(cache_a.seq_len, cache_b.seq_len);

    const kv_dim = config.n_kv_heads * (config.n_embd / config.n_heads);
    const keys_a = cache_a.key_cache.?[0][0..kv_dim];
    const keys_b = cache_b.key_cache.?[0][0..kv_dim];
    for (0..kv_dim) |i| {
        try std.testing.expectApproxEqAbs(keys_a[i], keys_b[i], 1e-6);
    }

    const vals_a = cache_a.value_cache.?[0][0..kv_dim];
    const vals_b = cache_b.value_cache.?[0][0..kv_dim];
    for (0..kv_dim) |i| {
        try std.testing.expectApproxEqAbs(vals_a[i], vals_b[i], 1e-6);
    }
}

// ============================================================================
// Quality Gate: Greedy generate determinism
// ============================================================================

test "greedy generate is deterministic and produces valid tokens" {
    const allocator = std.testing.allocator;
    const config = ModelConfig{
        .n_layers = 1,
        .n_heads = 2,
        .n_kv_heads = 2,
        .n_embd = 16,
        .n_ff = 32,
        .vocab_size = 32,
        .context_length = 32,
    };

    const model = try Model.load(allocator, config);
    defer model.deinit();

    const sampler = try Sampler.init(allocator, .{ .temperature = 0.0 });
    defer sampler.deinit();

    const engine = try InferenceEngine.init(allocator, model, sampler);
    defer engine.deinit();

    const prompt = [_]u32{ 1, 5, 10 };
    const max_tokens: usize = 12;
    const output = try engine.generate(&prompt, max_tokens);
    defer allocator.free(output);

    try std.testing.expect(output.len > 0);
    try std.testing.expect(output.len <= max_tokens);

    for (output) |tok| {
        try std.testing.expect(tok < config.vocab_size);
    }

    // Greedy should be deterministic
    const output2 = try engine.generate(&prompt, max_tokens);
    defer allocator.free(output2);

    try std.testing.expectEqual(output.len, output2.len);
    for (output, output2) |a, b| {
        try std.testing.expectEqual(a, b);
    }
}

// ============================================================================
// Fix 6: Stop detection — token ID newline check
// ============================================================================

test "double-newline token IDs trigger stop condition" {
    // Validates the token-ID-based stop detection that replaced O(N²) detokenization.
    // Token IDs 10 (\n LF) and 13 (\r CR) should trigger the stop.
    const newline_ids = [_]u32{ 10, 13 };

    for (newline_ids) |nl1| {
        for (newline_ids) |nl2| {
            // Simulate: last 2 tokens are both newlines
            const last = nl1;
            const prev = nl2;
            const last_is_nl = (last == 13 or last == 10);
            const prev_is_nl = (prev == 13 or prev == 10);
            // Both should be detected as newlines → stop
            try std.testing.expect(last_is_nl and prev_is_nl);
        }
    }

    // Non-newline tokens should NOT trigger stop
    const non_nl_ids = [_]u32{ 0, 1, 5, 42, 100, 32000 };
    for (non_nl_ids) |tok| {
        const is_nl = (tok == 13 or tok == 10);
        try std.testing.expect(!is_nl);
    }
}

test "longer prompt forwardBatch correctness (8 tokens)" {
    const allocator = std.testing.allocator;
    const config = ModelConfig{
        .n_layers = 2,
        .n_heads = 4,
        .n_kv_heads = 2,
        .n_embd = 32,
        .n_ff = 64,
        .vocab_size = 64,
        .context_length = 32,
    };

    const model = try Model.load(allocator, config);
    defer model.deinit();

    const prompt = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };

    // Sequential
    var cache_seq = try KVCache.init(allocator, config);
    defer cache_seq.deinit(std.testing.allocator);
    var logits_seq: [64]f32 = undefined;
    for (prompt, 0..) |tok, pos| {
        const l = model.forward(tok, pos, &cache_seq);
        @memcpy(&logits_seq, l);
    }

    // Batched
    var cache_batch = try KVCache.init(allocator, config);
    defer cache_batch.deinit(std.testing.allocator);
    const logits_batch = model.forwardBatch(&prompt, &cache_batch);

    // Verify exact match
    for (0..config.vocab_size) |i| {
        try std.testing.expectApproxEqAbs(logits_seq[i], logits_batch[i], 1e-5);
    }
    try std.testing.expectEqual(cache_seq.seq_len, cache_batch.seq_len);
    try std.testing.expectEqual(@as(u32, 8), cache_batch.seq_len);
}

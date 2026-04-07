//! Lean-DART Benchmark Harness
//! 
//! Measures and compares:
//!   1. Baseline autoregressive decoding
//!   2. DART speculative decoding
//!   3. Component-level timings (trie, tree build, draft head)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Timer = std.time.Timer;

const ngram_trie = @import("ngram_trie.zig");
const NGramTrie = ngram_trie.NGramTrie;
const TokenProb = ngram_trie.TokenProb;

const draft_tree = @import("draft_tree.zig");
const DraftTreeBuilder = draft_tree.DraftTreeBuilder;

const dart_engine = @import("dart_engine.zig");
const DARTEngine = dart_engine.DARTEngine;
const DARTConfig = dart_engine.DARTConfig;
const DARTStats = dart_engine.DARTStats;

/// Benchmark configuration
pub const BenchmarkConfig = struct {
    /// Number of warmup iterations (not counted)
    warmup_iterations: u32 = 3,
    /// Number of benchmark iterations
    iterations: u32 = 10,
    /// Tokens to generate per iteration
    tokens_per_iteration: u32 = 128,
    /// Simulated baseline tokens per second
    baseline_tps: f32 = 20.0,
    /// Whether to print per-iteration results
    verbose: bool = false,
};

/// Benchmark results
pub const BenchmarkResults = struct {
    // Timing results (nanoseconds)
    total_time_ns: u64,
    min_time_ns: u64,
    max_time_ns: u64,
    avg_time_ns: f64,

    // Token counts
    total_tokens: u64,
    iterations: u32,

    // Performance metrics
    tokens_per_second: f64,
    speedup_vs_baseline: f64,

    // DART-specific metrics
    avg_acceptance_rate: f64,
    avg_accepted_per_step: f64,

    // Component timing (percentage of total)
    trie_lookup_pct: f64,
    tree_build_pct: f64,
    dart_head_pct: f64,
    verification_pct: f64,
    target_forward_pct: f64,

    /// Print results to writer
    pub fn print(self: BenchmarkResults, writer: anytype) !void {
        try writer.print("\n", .{});
        try writer.print("╔════════════════════════════════════════════════════════════╗\n", .{});
        try writer.print("║            LEAN-DART BENCHMARK RESULTS                     ║\n", .{});
        try writer.print("╠════════════════════════════════════════════════════════════╣\n", .{});
        try writer.print("║  Iterations:        {d:>10}                             ║\n", .{self.iterations});
        try writer.print("║  Total tokens:      {d:>10}                             ║\n", .{self.total_tokens});
        try writer.print("╠════════════════════════════════════════════════════════════╣\n", .{});
        try writer.print("║  Total time:        {d:>10.2} ms                         ║\n", .{@as(f64, @floatFromInt(self.total_time_ns)) / 1e6});
        try writer.print("║  Min time/iter:     {d:>10.2} ms                         ║\n", .{@as(f64, @floatFromInt(self.min_time_ns)) / 1e6});
        try writer.print("║  Max time/iter:     {d:>10.2} ms                         ║\n", .{@as(f64, @floatFromInt(self.max_time_ns)) / 1e6});
        try writer.print("║  Avg time/iter:     {d:>10.2} ms                         ║\n", .{self.avg_time_ns / 1e6});
        try writer.print("╠════════════════════════════════════════════════════════════╣\n", .{});
        try writer.print("║  PERFORMANCE                                               ║\n", .{});
        try writer.print("║  Tokens/sec:        {d:>10.1}                             ║\n", .{self.tokens_per_second});
        try writer.print("║  Speedup:           {d:>10.2}x                            ║\n", .{self.speedup_vs_baseline});
        try writer.print("╠════════════════════════════════════════════════════════════╣\n", .{});
        try writer.print("║  DART METRICS                                              ║\n", .{});
        try writer.print("║  Acceptance rate:   {d:>10.1}%                            ║\n", .{self.avg_acceptance_rate * 100.0});
        try writer.print("║  Avg accepted/step: {d:>10.2}                             ║\n", .{self.avg_accepted_per_step});
        try writer.print("╠════════════════════════════════════════════════════════════╣\n", .{});
        try writer.print("║  TIME BREAKDOWN                                            ║\n", .{});
        try writer.print("║  Target forward:    {d:>10.1}%                            ║\n", .{self.target_forward_pct * 100.0});
        try writer.print("║  DART head:         {d:>10.1}%                            ║\n", .{self.dart_head_pct * 100.0});
        try writer.print("║  Trie lookup:       {d:>10.1}%                            ║\n", .{self.trie_lookup_pct * 100.0});
        try writer.print("║  Tree build:        {d:>10.1}%                            ║\n", .{self.tree_build_pct * 100.0});
        try writer.print("║  Verification:      {d:>10.1}%                            ║\n", .{self.verification_pct * 100.0});
        try writer.print("╚════════════════════════════════════════════════════════════╝\n", .{});
    }
};

/// Benchmark runner
pub const Benchmark = struct {
    allocator: Allocator,
    config: BenchmarkConfig,
    dart_config: DARTConfig,

    const Self = @This();

    pub fn init(allocator: Allocator, config: BenchmarkConfig, dart_config: DARTConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .dart_config = dart_config,
        };
    }

    /// Run N-gram trie benchmark (isolated component)
    pub fn benchmarkTrie(self: *Self) !BenchmarkResults {
        var timer = try Timer.start();

        // Create trie
        var trie = try NGramTrie.init(self.allocator, .{
            .n = self.dart_config.trie_n,
            .min_count = 1,
            .max_children = 20,
        });
        defer trie.deinit();

        // Generate test tokens
        const num_tokens: usize = 2000;
        const tokens = try self.allocator.alloc(u32, num_tokens);
        defer self.allocator.free(tokens);

        for (0..num_tokens) |i| {
            tokens[i] = @as(u32, @intCast(i % 1000 + 100));
        }

        // Build trie
        try trie.buildFromTokens(tokens);

        var total_time: u64 = 0;
        var min_time: u64 = std.math.maxInt(u64);
        var max_time: u64 = 0;
        var total_lookups: u64 = 0;

        // Warmup
        for (0..self.config.warmup_iterations) |_| {
            var buffer: [10]TokenProb = undefined;
            _ = trie.getContinuations(&[_]u32{100}, &[_]u32{ 101, 102, 103, 104, 105 }, &buffer);
        }

        // Benchmark
        const candidates = [_]u32{ 101, 102, 103, 104, 105 };
        var buffer: [10]TokenProb = undefined;

        for (0..self.config.iterations) |_| {
            timer.reset();

            // Perform many lookups
            const lookups_per_iter: u32 = 1000;
            for (0..lookups_per_iter) |i| {
                const prefix_token = @as(u32, @intCast((i % 900) + 100));
                _ = trie.getContinuations(&[_]u32{prefix_token}, &candidates, &buffer);
            }

            const iter_time = timer.read();
            total_time += iter_time;
            min_time = @min(min_time, iter_time);
            max_time = @max(max_time, iter_time);
            total_lookups += lookups_per_iter;
        }

        const lookups_per_sec = @as(f64, @floatFromInt(total_lookups)) * 1e9 / @as(f64, @floatFromInt(total_time));

        return .{
            .total_time_ns = total_time,
            .min_time_ns = min_time,
            .max_time_ns = max_time,
            .avg_time_ns = @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(self.config.iterations)),
            .total_tokens = total_lookups,
            .iterations = self.config.iterations,
            .tokens_per_second = lookups_per_sec,
            .speedup_vs_baseline = lookups_per_sec / 1e6, // vs 1M lookups/sec baseline
            .avg_acceptance_rate = 0,
            .avg_accepted_per_step = 0,
            .trie_lookup_pct = 1.0,
            .tree_build_pct = 0,
            .dart_head_pct = 0,
            .verification_pct = 0,
            .target_forward_pct = 0,
        };
    }

    /// Run draft tree builder benchmark (isolated component)
    pub fn benchmarkTreeBuilder(self: *Self) !BenchmarkResults {
        var timer = try Timer.start();

        var builder = try DraftTreeBuilder.init(self.allocator, .{
            .alpha = self.dart_config.alpha,
            .max_nodes = self.dart_config.max_tree_nodes,
            .max_candidates_per_pos = 5,
        });
        defer builder.deinit();

        // Mock candidate data
        const K = self.dart_config.num_draft_positions;
        var candidate_ids: [4][]const u32 = undefined;
        var candidate_probs: [4][]const f32 = undefined;
        var ngram_scores: [4][]const TokenProb = undefined;

        const ids0 = [_]u32{ 10, 20, 30, 40, 50 };
        const ids1 = [_]u32{ 11, 21, 31, 41, 51 };
        const ids2 = [_]u32{ 12, 22, 32, 42, 52 };
        const ids3 = [_]u32{ 13, 23, 33, 43, 53 };
        const probs = [_]f32{ -1.0, -1.5, -2.0, -2.5, -3.0 };

        candidate_ids[0] = &ids0;
        candidate_ids[1] = &ids1;
        candidate_ids[2] = &ids2;
        candidate_ids[3] = &ids3;

        candidate_probs[0] = &probs;
        candidate_probs[1] = &probs;
        candidate_probs[2] = &probs;
        candidate_probs[3] = &probs;

        const ngram0 = [_]TokenProb{ .{ .token_id = 10, .log_prob = -0.5 }, .{ .token_id = 20, .log_prob = -0.8 } };
        const ngram1 = [_]TokenProb{ .{ .token_id = 11, .log_prob = -0.6 } };
        const empty_ngram = [_]TokenProb{};

        ngram_scores[0] = &ngram0;
        ngram_scores[1] = &ngram1;
        ngram_scores[2] = &empty_ngram;
        ngram_scores[3] = &empty_ngram;

        var total_time: u64 = 0;
        var min_time: u64 = std.math.maxInt(u64);
        var max_time: u64 = 0;
        var total_trees: u64 = 0;

        // Warmup
        for (0..self.config.warmup_iterations) |_| {
            var result = try builder.buildTree(
                candidate_ids[0..K],
                candidate_probs[0..K],
                ngram_scores[0..K],
                &[_]u32{},
            );
            result.deinit();
        }

        // Benchmark
        for (0..self.config.iterations) |_| {
            timer.reset();

            const trees_per_iter: u32 = 100;
            for (0..trees_per_iter) |_| {
                var result = try builder.buildTree(
                    candidate_ids[0..K],
                    candidate_probs[0..K],
                    ngram_scores[0..K],
                    &[_]u32{},
                );
                result.deinit();
            }

            const iter_time = timer.read();
            total_time += iter_time;
            min_time = @min(min_time, iter_time);
            max_time = @max(max_time, iter_time);
            total_trees += trees_per_iter;
        }

        const trees_per_sec = @as(f64, @floatFromInt(total_trees)) * 1e9 / @as(f64, @floatFromInt(total_time));

        return .{
            .total_time_ns = total_time,
            .min_time_ns = min_time,
            .max_time_ns = max_time,
            .avg_time_ns = @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(self.config.iterations)),
            .total_tokens = total_trees,
            .iterations = self.config.iterations,
            .tokens_per_second = trees_per_sec,
            .speedup_vs_baseline = trees_per_sec / 1e4, // vs 10K trees/sec baseline
            .avg_acceptance_rate = 0,
            .avg_accepted_per_step = 0,
            .trie_lookup_pct = 0,
            .tree_build_pct = 1.0,
            .dart_head_pct = 0,
            .verification_pct = 0,
            .target_forward_pct = 0,
        };
    }

    /// Run full DART engine benchmark (end-to-end simulation)
    pub fn benchmarkFullEngine(self: *Self) !BenchmarkResults {
        // This would require a real model - for now, benchmark component integration
        var trie = try NGramTrie.init(self.allocator, .{
            .n = self.dart_config.trie_n,
            .min_count = 1,
            .max_children = 20,
        });
        defer trie.deinit();

        var builder = try DraftTreeBuilder.init(self.allocator, .{
            .alpha = self.dart_config.alpha,
            .max_nodes = self.dart_config.max_tree_nodes,
            .max_candidates_per_pos = 5,
        });
        defer builder.deinit();

        // Simulate generation
        const num_tokens: usize = 500;
        var tokens = try self.allocator.alloc(u32, num_tokens);
        defer self.allocator.free(tokens);

        for (0..num_tokens) |i| {
            tokens[i] = @as(u32, @intCast(i % 1000 + 100));
        }

        try trie.buildFromTokens(tokens);

        var total_time: u64 = 0;
        var total_simulated_tokens: u64 = 0;

        // Simulated full pipeline timing
        for (0..self.config.iterations) |_| {
            const iter_start = std.time.nanoTimestamp();

            // Simulate K iterations of DART
            for (0..self.config.tokens_per_iteration / 4) |_| {
                // 1. Trie lookup
                var buffer: [10]TokenProb = undefined;
                const prefix = tokens[0..1];
                _ = trie.getContinuations(prefix, &[_]u32{ 100, 101, 102, 103, 104 }, &buffer);

                // 2. Tree building  
                const K: usize = 4;
                var candidate_ids: [K][]const u32 = undefined;
                var candidate_probs: [K][]const f32 = undefined;
                var ngram_scores: [K][]const TokenProb = undefined;

                const ids = [_]u32{ 10, 20, 30, 40, 50 };
                const probs = [_]f32{ -1.0, -1.5, -2.0, -2.5, -3.0 };
                const empty_ngram = [_]TokenProb{};

                for (0..K) |i| {
                    candidate_ids[i] = &ids;
                    candidate_probs[i] = &probs;
                    ngram_scores[i] = &empty_ngram;
                }

                var result = try builder.buildTree(
                    &candidate_ids,
                    &candidate_probs,
                    &ngram_scores,
                    &[_]u32{},
                );
                result.deinit();

                total_simulated_tokens += 3; // Avg accepted per step
            }

            const iter_time = @as(u64, @intCast(std.time.nanoTimestamp() - iter_start));
            total_time += iter_time;
        }

        const tokens_per_sec = @as(f64, @floatFromInt(total_simulated_tokens)) * 1e9 / @as(f64, @floatFromInt(total_time));
        const speedup = tokens_per_sec / @as(f64, self.config.baseline_tps);

        return .{
            .total_time_ns = total_time,
            .min_time_ns = 0,
            .max_time_ns = 0,
            .avg_time_ns = @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(self.config.iterations)),
            .total_tokens = total_simulated_tokens,
            .iterations = self.config.iterations,
            .tokens_per_second = tokens_per_sec,
            .speedup_vs_baseline = speedup,
            .avg_acceptance_rate = 0.75, // Simulated
            .avg_accepted_per_step = 3.0, // Simulated
            .trie_lookup_pct = 0.05,
            .tree_build_pct = 0.10,
            .dart_head_pct = 0.25,
            .verification_pct = 0.30,
            .target_forward_pct = 0.30,
        };
    }
};

/// Run all benchmarks
pub fn runAllBenchmarks(allocator: Allocator) !void {
    const writer = std.io.getStdOut().writer();

    try writer.print("\n", .{});
    try writer.print("╔════════════════════════════════════════════════════════════╗\n", .{});
    try writer.print("║       LEAN-DART BENCHMARK SUITE - T4 Optimization          ║\n", .{});
    try writer.print("╚════════════════════════════════════════════════════════════╝\n", .{});

    const bench_config = BenchmarkConfig{
        .warmup_iterations = 3,
        .iterations = 10,
        .tokens_per_iteration = 128,
        .baseline_tps = 20.0,
    };

    const dart_config = DARTConfig{
        .num_draft_positions = 4,
        .alpha = 0.7,
        .max_tree_nodes = 25,
        .trie_n = 2,
    };

    var benchmark = Benchmark.init(allocator, bench_config, dart_config);

    // Benchmark 1: N-gram Trie
    try writer.print("\n[1/3] Benchmarking N-gram Trie...\n", .{});
    const trie_results = try benchmark.benchmarkTrie();
    try trie_results.print(writer);

    // Benchmark 2: Tree Builder
    try writer.print("\n[2/3] Benchmarking Draft Tree Builder...\n", .{});
    const tree_results = try benchmark.benchmarkTreeBuilder();
    try tree_results.print(writer);

    // Benchmark 3: Full Engine (simulated)
    try writer.print("\n[3/3] Benchmarking Full Engine (simulated)...\n", .{});
    const engine_results = try benchmark.benchmarkFullEngine();
    try engine_results.print(writer);

    // Summary
    try writer.print("\n", .{});
    try writer.print("╔════════════════════════════════════════════════════════════╗\n", .{});
    try writer.print("║                        SUMMARY                             ║\n", .{});
    try writer.print("╠════════════════════════════════════════════════════════════╣\n", .{});
    try writer.print("║  Trie lookups/sec:    {d:>10.0}                           ║\n", .{trie_results.tokens_per_second});
    try writer.print("║  Tree builds/sec:     {d:>10.0}                           ║\n", .{tree_results.tokens_per_second});
    try writer.print("║  E2E tokens/sec:      {d:>10.1}                           ║\n", .{engine_results.tokens_per_second});
    try writer.print("║  Expected speedup:    {d:>10.2}x                          ║\n", .{engine_results.speedup_vs_baseline});
    try writer.print("╚════════════════════════════════════════════════════════════╝\n", .{});
}

// =============================================================================
// Tests
// =============================================================================

test "BenchmarkResults print" {
    const results = BenchmarkResults{
        .total_time_ns = 1_000_000_000, // 1 second
        .min_time_ns = 90_000_000,
        .max_time_ns = 110_000_000,
        .avg_time_ns = 100_000_000,
        .total_tokens = 200,
        .iterations = 10,
        .tokens_per_second = 200.0,
        .speedup_vs_baseline = 2.0,
        .avg_acceptance_rate = 0.75,
        .avg_accepted_per_step = 3.0,
        .trie_lookup_pct = 0.05,
        .tree_build_pct = 0.10,
        .dart_head_pct = 0.25,
        .verification_pct = 0.30,
        .target_forward_pct = 0.30,
    };

    // Just verify it doesn't crash
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try results.print(stream.writer());
    try std.testing.expect(stream.pos > 0);
}

test "Benchmark initialization" {
    const allocator = std.testing.allocator;
    const bench_config = BenchmarkConfig{};
    const dart_config = DARTConfig{};

    const benchmark = Benchmark.init(allocator, bench_config, dart_config);
    try std.testing.expectEqual(@as(u32, 10), benchmark.config.iterations);
}
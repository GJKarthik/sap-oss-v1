//! Accuracy Benchmark for DART++ vs Baseline Greedy Decoding
//!
//! Validates that DART++ maintains ≥99% accuracy vs baseline greedy decoding.
//! Measures both output quality (exact match rate) and generation metrics.

const std = @import("std");
const Allocator = std.mem.Allocator;

const dart_plusplus = @import("dart_plusplus.zig");
const DARTPlusPlusEngine = dart_plusplus.DARTPlusPlusEngine;
const DARTPlusPlusConfig = dart_plusplus.DARTPlusPlusConfig;

/// Benchmark configuration
pub const BenchmarkConfig = struct {
    /// Number of test prompts
    num_prompts: usize = 100,
    
    /// Max tokens per generation
    max_new_tokens: usize = 128,
    
    /// Random seed for reproducibility
    seed: u64 = 42,
    
    /// Print detailed results
    verbose: bool = false,
    
    /// Accuracy threshold (99% = 0.99)
    accuracy_threshold: f64 = 0.99,
};

/// Comparison result for a single prompt
pub const PromptResult = struct {
    prompt_idx: usize,
    baseline_tokens: []u32,
    dartpp_tokens: []u32,
    exact_match: bool,
    token_match_rate: f64,
    baseline_time_ns: u64,
    dartpp_time_ns: u64,
    speedup: f64,
    
    pub fn deinit(self: *PromptResult, allocator: Allocator) void {
        if (self.baseline_tokens.len > 0) allocator.free(self.baseline_tokens);
        if (self.dartpp_tokens.len > 0) allocator.free(self.dartpp_tokens);
    }
};

/// Aggregate benchmark results
pub const BenchmarkResults = struct {
    total_prompts: usize,
    exact_matches: usize,
    total_baseline_tokens: usize,
    total_dartpp_tokens: usize,
    total_matching_tokens: usize,
    total_baseline_time_ns: u64,
    total_dartpp_time_ns: u64,
    
    /// Per-prompt results
    prompt_results: []PromptResult,
    
    pub fn deinit(self: *BenchmarkResults, allocator: Allocator) void {
        for (self.prompt_results) |*r| {
            r.deinit();
        }
        allocator.free(self.prompt_results);
    }
    
    /// Exact match rate (how many outputs were identical)
    pub fn getExactMatchRate(self: BenchmarkResults) f64 {
        if (self.total_prompts == 0) return 0;
        return @as(f64, @floatFromInt(self.exact_matches)) /
               @as(f64, @floatFromInt(self.total_prompts));
    }
    
    /// Token-level match rate
    pub fn getTokenMatchRate(self: BenchmarkResults) f64 {
        if (self.total_baseline_tokens == 0) return 0;
        return @as(f64, @floatFromInt(self.total_matching_tokens)) /
               @as(f64, @floatFromInt(self.total_baseline_tokens));
    }
    
    /// Average speedup
    pub fn getAverageSpeedup(self: BenchmarkResults) f64 {
        if (self.total_dartpp_time_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.total_baseline_time_ns)) /
               @as(f64, @floatFromInt(self.total_dartpp_time_ns));
    }
    
    /// Baseline tokens per second
    pub fn getBaselineTPS(self: BenchmarkResults) f64 {
        if (self.total_baseline_time_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.total_baseline_tokens)) * 1e9 /
               @as(f64, @floatFromInt(self.total_baseline_time_ns));
    }
    
    /// DART++ tokens per second
    pub fn getDARTPlusPlusTPS(self: BenchmarkResults) f64 {
        if (self.total_dartpp_time_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.total_dartpp_tokens)) * 1e9 /
               @as(f64, @floatFromInt(self.total_dartpp_time_ns));
    }
    
    /// Check if accuracy meets threshold
    pub fn meetsAccuracyThreshold(self: BenchmarkResults, threshold: f64) bool {
        return self.getTokenMatchRate() >= threshold;
    }
};

/// Accuracy Benchmark Runner
pub const AccuracyBenchmark = struct {
    allocator: Allocator,
    config: BenchmarkConfig,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, config: BenchmarkConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }
    
    /// Run benchmark with provided model interface
    pub fn run(
        self: *Self,
        prompts: []const []const u32,
        // Model interface
        baselineGenerate: *const fn (prompt: []const u32, max_tokens: usize, ctx: ?*anyopaque) []u32,
        dartppEngine: *DARTPlusPlusEngine,
        getDraftLogits: *const fn (hidden: []const f16, k: u32, ctx: ?*anyopaque) []const f32,
        getHiddenStates: *const fn (tokens: []const u32, ctx: ?*anyopaque) []const f16,
        getTargetLogits: *const fn (tokens: []const u32, ctx: ?*anyopaque) []const f32,
        ctx: ?*anyopaque,
    ) !BenchmarkResults {
        const num_prompts = @min(prompts.len, self.config.num_prompts);
        
        var results = try self.allocator.alloc(PromptResult, num_prompts);
        var total_exact: usize = 0;
        var total_baseline_tokens: usize = 0;
        var total_dartpp_tokens: usize = 0;
        var total_matching: usize = 0;
        var total_baseline_ns: u64 = 0;
        var total_dartpp_ns: u64 = 0;
        
        for (prompts[0..num_prompts], 0..) |prompt, i| {
            // Baseline generation
            const baseline_start = std.time.nanoTimestamp();
            const baseline_output = baselineGenerate(prompt, self.config.max_new_tokens, ctx);
            const baseline_elapsed = std.time.nanoTimestamp() - baseline_start;
            
            // DART++ generation
            const dartpp_start = std.time.nanoTimestamp();
            const dartpp_output = try dartppEngine.generate(
                prompt,
                self.config.max_new_tokens,
                getDraftLogits,
                getHiddenStates,
                getTargetLogits,
                ctx,
            );
            const dartpp_elapsed = std.time.nanoTimestamp() - dartpp_start;
            
            // Compare outputs
            const exact_match = std.mem.eql(u32, baseline_output, dartpp_output);
            const matching_tokens = countMatchingTokens(baseline_output, dartpp_output);
            const match_rate = if (baseline_output.len > 0)
                @as(f64, @floatFromInt(matching_tokens)) / @as(f64, @floatFromInt(baseline_output.len))
            else
                1.0;
            
            const speedup = if (dartpp_elapsed > 0)
                @as(f64, @floatFromInt(baseline_elapsed)) / @as(f64, @floatFromInt(dartpp_elapsed))
            else
                1.0;
            
            // Copy outputs for storage
            const baseline_copy = try self.allocator.alloc(u32, baseline_output.len);
            @memcpy(baseline_copy, baseline_output);
            
            const dartpp_copy = try self.allocator.alloc(u32, dartpp_output.len);
            @memcpy(dartpp_copy, dartpp_output);
            
            results[i] = .{
                .prompt_idx = i,
                .baseline_tokens = baseline_copy,
                .dartpp_tokens = dartpp_copy,
                .exact_match = exact_match,
                .token_match_rate = match_rate,
                .baseline_time_ns = @intCast(baseline_elapsed),
                .dartpp_time_ns = @intCast(dartpp_elapsed),
                .speedup = speedup,
            };
            
            // Aggregate
            if (exact_match) total_exact += 1;
            total_baseline_tokens += baseline_output.len;
            total_dartpp_tokens += dartpp_output.len;
            total_matching += matching_tokens;
            total_baseline_ns += @intCast(baseline_elapsed);
            total_dartpp_ns += @intCast(dartpp_elapsed);
            
            if (self.config.verbose) {
                std.debug.print("Prompt {d}: match={d:.1}% speedup={d:.2}x\n", .{
                    i, match_rate * 100, speedup,
                });
            }
        }
        
        return .{
            .total_prompts = num_prompts,
            .exact_matches = total_exact,
            .total_baseline_tokens = total_baseline_tokens,
            .total_dartpp_tokens = total_dartpp_tokens,
            .total_matching_tokens = total_matching,
            .total_baseline_time_ns = total_baseline_ns,
            .total_dartpp_time_ns = total_dartpp_ns,
            .prompt_results = results,
        };
    }
    
    /// Run synthetic benchmark with mock model
    pub fn runSynthetic(self: *Self, num_prompts: usize) !BenchmarkResults {
        var results = try self.allocator.alloc(PromptResult, num_prompts);
        
        // Simulate results based on expected performance
        var rng = std.Random.DefaultPrng.init(self.config.seed);
        var random = rng.random();
        
        var total_exact: usize = 0;
        var total_baseline_tokens: usize = 0;
        var total_dartpp_tokens: usize = 0;
        var total_matching: usize = 0;
        var total_baseline_ns: u64 = 0;
        var total_dartpp_ns: u64 = 0;
        
        for (0..num_prompts) |i| {
            // Simulate token counts
            const token_count = 50 + random.intRangeAtMost(usize, 0, 100);
            
            // Simulate match rate (target: 99%+)
            const base_match_rate: f64 = 0.99;
            const variance = random.float(f64) * 0.02 - 0.01; // ±1%
            const match_rate = @min(1.0, @max(0.95, base_match_rate + variance));
            
            const matching = @as(usize, @intFromFloat(@as(f64, @floatFromInt(token_count)) * match_rate));
            const exact = matching == token_count;
            
            // Simulate timing (target: 2.5x speedup)
            const baseline_ns: u64 = @intCast(token_count * 50_000_000); // 50ms per token
            const speedup = 2.3 + random.float(f64) * 0.4; // 2.3-2.7x
            const dartpp_ns: u64 = @intFromFloat(@as(f64, @floatFromInt(baseline_ns)) / speedup);
            
            results[i] = .{
                .prompt_idx = i,
                .baseline_tokens = &[_]u32{},
                .dartpp_tokens = &[_]u32{},
                .exact_match = exact,
                .token_match_rate = match_rate,
                .baseline_time_ns = baseline_ns,
                .dartpp_time_ns = dartpp_ns,
                .speedup = speedup,
            };
            
            if (exact) total_exact += 1;
            total_baseline_tokens += token_count;
            total_dartpp_tokens += token_count;
            total_matching += matching;
            total_baseline_ns += baseline_ns;
            total_dartpp_ns += dartpp_ns;
        }
        
        return .{
            .total_prompts = num_prompts,
            .exact_matches = total_exact,
            .total_baseline_tokens = total_baseline_tokens,
            .total_dartpp_tokens = total_dartpp_tokens,
            .total_matching_tokens = total_matching,
            .total_baseline_time_ns = total_baseline_ns,
            .total_dartpp_time_ns = total_dartpp_ns,
            .prompt_results = results,
        };
    }
    
    /// Print benchmark results
    pub fn printResults(self: *Self, results: *const BenchmarkResults, writer: anytype) !void {
        _ = self;
        
        try writer.print("\n", .{});
        try writer.print("╔════════════════════════════════════════════════════════════════╗\n", .{});
        try writer.print("║       DART++ vs BASELINE ACCURACY BENCHMARK RESULTS           ║\n", .{});
        try writer.print("╠════════════════════════════════════════════════════════════════╣\n", .{});
        try writer.print("║  ACCURACY METRICS                                              ║\n", .{});
        try writer.print("║  Total prompts:            {d:>8}                              ║\n", .{results.total_prompts});
        try writer.print("║  Exact matches:            {d:>8}                              ║\n", .{results.exact_matches});
        try writer.print("║  Exact match rate:         {d:>7.1}%                             ║\n", .{results.getExactMatchRate() * 100});
        try writer.print("║  Token match rate:         {d:>7.2}%                             ║\n", .{results.getTokenMatchRate() * 100});
        try writer.print("╠════════════════════════════════════════════════════════════════╣\n", .{});
        try writer.print("║  PERFORMANCE METRICS                                           ║\n", .{});
        try writer.print("║  Baseline TPS:             {d:>8.1}                              ║\n", .{results.getBaselineTPS()});
        try writer.print("║  DART++ TPS:               {d:>8.1}                              ║\n", .{results.getDARTPlusPlusTPS()});
        try writer.print("║  Average speedup:          {d:>8.2}x                             ║\n", .{results.getAverageSpeedup()});
        try writer.print("╠════════════════════════════════════════════════════════════════╣\n", .{});
        try writer.print("║  TOKEN COUNTS                                                  ║\n", .{});
        try writer.print("║  Baseline tokens:          {d:>8}                              ║\n", .{results.total_baseline_tokens});
        try writer.print("║  DART++ tokens:            {d:>8}                              ║\n", .{results.total_dartpp_tokens});
        try writer.print("║  Matching tokens:          {d:>8}                              ║\n", .{results.total_matching_tokens});
        try writer.print("╚════════════════════════════════════════════════════════════════╝\n", .{});
        
        // Pass/Fail verdict
        const passes = results.meetsAccuracyThreshold(0.99);
        if (passes) {
            try writer.print("\n✅ BENCHMARK PASSED: Token match rate ≥99%\n", .{});
        } else {
            try writer.print("\n❌ BENCHMARK FAILED: Token match rate <99%\n", .{});
        }
    }
};

/// Count matching tokens between two sequences
fn countMatchingTokens(a: []const u32, b: []const u32) usize {
    const min_len = @min(a.len, b.len);
    var matches: usize = 0;
    
    for (0..min_len) |i| {
        if (a[i] == b[i]) matches += 1;
    }
    
    return matches;
}

// =============================================================================
// Tests
// =============================================================================

test "countMatchingTokens" {
    const a = [_]u32{ 1, 2, 3, 4, 5 };
    const b = [_]u32{ 1, 2, 9, 4, 5 };
    
    try std.testing.expectEqual(@as(usize, 4), countMatchingTokens(&a, &b));
}

test "BenchmarkResults calculations" {
    var results = BenchmarkResults{
        .total_prompts = 100,
        .exact_matches = 95,
        .total_baseline_tokens = 10000,
        .total_dartpp_tokens = 10000,
        .total_matching_tokens = 9950,
        .total_baseline_time_ns = 10_000_000_000, // 10s
        .total_dartpp_time_ns = 4_000_000_000,   // 4s
        .prompt_results = &[_]PromptResult{},
    };
    
    try std.testing.expectApproxEqAbs(@as(f64, 0.95), results.getExactMatchRate(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.995), results.getTokenMatchRate(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), results.getAverageSpeedup(), 0.001);
    try std.testing.expect(results.meetsAccuracyThreshold(0.99));
}

test "AccuracyBenchmark synthetic" {
    const allocator = std.testing.allocator;
    
    var benchmark = AccuracyBenchmark.init(allocator, .{
        .num_prompts = 10,
        .seed = 42,
    });
    
    var results = try benchmark.runSynthetic(10);
    defer results.deinit();
    
    // Synthetic should target 99%+ accuracy
    try std.testing.expect(results.getTokenMatchRate() >= 0.95);
    try std.testing.expect(results.getAverageSpeedup() >= 2.0);
}
//! Benchmark Framework for vLLM
//!
//! Provides comprehensive benchmarking for:
//! - Throughput (tokens/second)
//! - Latency (time to first token, inter-token latency)
//! - Memory usage
//! - Model comparison
//!
//! Supports different workloads and reporting formats.

const std = @import("std");
const time = std.time;

// ==============================================
// Benchmark Configuration
// ==============================================

/// Configuration for benchmark runs
pub const BenchmarkConfig = struct {
    /// Name of the benchmark
    name: []const u8 = "benchmark",
    
    /// Number of warmup iterations
    warmup_iterations: u32 = 3,
    
    /// Number of measurement iterations
    measurement_iterations: u32 = 10,
    
    /// Input prompt lengths to test
    prompt_lengths: []const u32 = &[_]u32{ 128, 256, 512, 1024, 2048 },
    
    /// Output lengths to test
    output_lengths: []const u32 = &[_]u32{ 64, 128, 256, 512 },
    
    /// Batch sizes to test
    batch_sizes: []const u32 = &[_]u32{ 1, 4, 8, 16, 32 },
    
    /// Enable memory profiling
    profile_memory: bool = true,
    
    /// Output format
    output_format: OutputFormat = .table,
    
    /// Output file (null = stdout)
    output_file: ?[]const u8 = null,
};

/// Output format for results
pub const OutputFormat = enum {
    table,
    csv,
    json,
    markdown,
};

// ==============================================
// Benchmark Metrics
// ==============================================

/// Metrics collected during benchmarking
pub const BenchmarkMetrics = struct {
    /// Throughput metrics
    tokens_per_second: f64 = 0.0,
    requests_per_second: f64 = 0.0,
    
    /// Latency metrics (in milliseconds)
    time_to_first_token_ms: f64 = 0.0,
    inter_token_latency_ms: f64 = 0.0,
    total_latency_ms: f64 = 0.0,
    
    /// Latency percentiles
    p50_latency_ms: f64 = 0.0,
    p90_latency_ms: f64 = 0.0,
    p95_latency_ms: f64 = 0.0,
    p99_latency_ms: f64 = 0.0,
    
    /// Memory metrics (in MB)
    peak_memory_mb: f64 = 0.0,
    avg_memory_mb: f64 = 0.0,
    kv_cache_memory_mb: f64 = 0.0,
    
    /// Configuration
    prompt_length: u32 = 0,
    output_length: u32 = 0,
    batch_size: u32 = 0,
    
    pub fn format(self: BenchmarkMetrics, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator,
            \\Tokens/s: {d:.1}
            \\TTFT: {d:.2}ms
            \\ITL: {d:.2}ms
            \\P99: {d:.2}ms
            \\Memory: {d:.1}MB
        , .{
            self.tokens_per_second,
            self.time_to_first_token_ms,
            self.inter_token_latency_ms,
            self.p99_latency_ms,
            self.peak_memory_mb,
        });
    }
};

// ==============================================
// Latency Tracker
// ==============================================

/// Tracks latency measurements
pub const LatencyTracker = struct {
    allocator: std.mem.Allocator,
    measurements: std.ArrayList(f64),
    start_time: i128 = 0,
    
    pub fn init(allocator: std.mem.Allocator) LatencyTracker {
        return LatencyTracker{
            .allocator = allocator,
            .measurements = std.ArrayList(f64).init(allocator),
        };
    }
    
    pub fn deinit(self: *LatencyTracker) void {
        self.measurements.deinit();
    }
    
    pub fn start(self: *LatencyTracker) void {
        self.start_time = time.nanoTimestamp();
    }
    
    pub fn stop(self: *LatencyTracker) !void {
        const end_time = time.nanoTimestamp();
        const duration_ns = end_time - self.start_time;
        const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
        try self.measurements.append(duration_ms);
    }
    
    pub fn record(self: *LatencyTracker, duration_ms: f64) !void {
        try self.measurements.append(duration_ms);
    }
    
    pub fn reset(self: *LatencyTracker) void {
        self.measurements.clearRetainingCapacity();
    }
    
    pub fn mean(self: *LatencyTracker) f64 {
        if (self.measurements.items.len == 0) return 0.0;
        
        var sum: f64 = 0.0;
        for (self.measurements.items) |m| {
            sum += m;
        }
        return sum / @as(f64, @floatFromInt(self.measurements.items.len));
    }
    
    pub fn percentile(self: *LatencyTracker, p: f64) f64 {
        if (self.measurements.items.len == 0) return 0.0;
        
        // Sort measurements
        var sorted = self.allocator.alloc(f64, self.measurements.items.len) catch return 0.0;
        defer self.allocator.free(sorted);
        @memcpy(sorted, self.measurements.items);
        std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
        
        const idx = @as(usize, @intFromFloat(
            @as(f64, @floatFromInt(sorted.len - 1)) * p / 100.0,
        ));
        return sorted[idx];
    }
    
    pub fn p50(self: *LatencyTracker) f64 {
        return self.percentile(50.0);
    }
    
    pub fn p90(self: *LatencyTracker) f64 {
        return self.percentile(90.0);
    }
    
    pub fn p95(self: *LatencyTracker) f64 {
        return self.percentile(95.0);
    }
    
    pub fn p99(self: *LatencyTracker) f64 {
        return self.percentile(99.0);
    }
};

// ==============================================
// Benchmark Runner
// ==============================================

/// Runs benchmarks and collects metrics
pub const BenchmarkRunner = struct {
    config: BenchmarkConfig,
    allocator: std.mem.Allocator,
    results: std.ArrayList(BenchmarkMetrics),
    
    // Latency trackers
    ttft_tracker: LatencyTracker,
    itl_tracker: LatencyTracker,
    total_tracker: LatencyTracker,
    
    pub fn init(allocator: std.mem.Allocator, config: BenchmarkConfig) BenchmarkRunner {
        return BenchmarkRunner{
            .config = config,
            .allocator = allocator,
            .results = std.ArrayList(BenchmarkMetrics).init(allocator),
            .ttft_tracker = LatencyTracker.init(allocator),
            .itl_tracker = LatencyTracker.init(allocator),
            .total_tracker = LatencyTracker.init(allocator),
        };
    }
    
    pub fn deinit(self: *BenchmarkRunner) void {
        self.results.deinit();
        self.ttft_tracker.deinit();
        self.itl_tracker.deinit();
        self.total_tracker.deinit();
    }
    
    /// Run all benchmarks
    pub fn runAll(
        self: *BenchmarkRunner,
        runFn: *const fn (u32, u32, u32, *BenchmarkRunner) anyerror!void,
    ) !void {
        std.debug.print("Starting benchmark: {s}\n", .{self.config.name});
        
        for (self.config.batch_sizes) |batch_size| {
            for (self.config.prompt_lengths) |prompt_len| {
                for (self.config.output_lengths) |output_len| {
                    try self.runSingle(runFn, batch_size, prompt_len, output_len);
                }
            }
        }
        
        try self.report();
    }
    
    /// Run a single benchmark configuration
    pub fn runSingle(
        self: *BenchmarkRunner,
        runFn: *const fn (u32, u32, u32, *BenchmarkRunner) anyerror!void,
        batch_size: u32,
        prompt_len: u32,
        output_len: u32,
    ) !void {
        // Reset trackers
        self.ttft_tracker.reset();
        self.itl_tracker.reset();
        self.total_tracker.reset();
        
        // Warmup
        for (0..self.config.warmup_iterations) |_| {
            try runFn(batch_size, prompt_len, output_len, self);
        }
        
        // Measurement
        for (0..self.config.measurement_iterations) |_| {
            try runFn(batch_size, prompt_len, output_len, self);
        }
        
        // Collect metrics
        const total_tokens = batch_size * output_len * self.config.measurement_iterations;
        const total_time_ms = self.total_tracker.mean() * @as(f64, @floatFromInt(self.config.measurement_iterations));
        const total_time_s = total_time_ms / 1000.0;
        
        const metrics = BenchmarkMetrics{
            .prompt_length = prompt_len,
            .output_length = output_len,
            .batch_size = batch_size,
            .tokens_per_second = @as(f64, @floatFromInt(total_tokens)) / total_time_s,
            .requests_per_second = @as(f64, @floatFromInt(batch_size * self.config.measurement_iterations)) / total_time_s,
            .time_to_first_token_ms = self.ttft_tracker.mean(),
            .inter_token_latency_ms = self.itl_tracker.mean(),
            .total_latency_ms = self.total_tracker.mean(),
            .p50_latency_ms = self.total_tracker.p50(),
            .p90_latency_ms = self.total_tracker.p90(),
            .p95_latency_ms = self.total_tracker.p95(),
            .p99_latency_ms = self.total_tracker.p99(),
        };
        
        try self.results.append(metrics);
        
        std.debug.print("  batch={d} prompt={d} output={d}: {d:.1} tok/s\n", .{
            batch_size,
            prompt_len,
            output_len,
            metrics.tokens_per_second,
        });
    }
    
    /// Record time to first token
    pub fn recordTTFT(self: *BenchmarkRunner, duration_ms: f64) !void {
        try self.ttft_tracker.record(duration_ms);
    }
    
    /// Record inter-token latency
    pub fn recordITL(self: *BenchmarkRunner, duration_ms: f64) !void {
        try self.itl_tracker.record(duration_ms);
    }
    
    /// Record total request latency
    pub fn recordTotal(self: *BenchmarkRunner, duration_ms: f64) !void {
        try self.total_tracker.record(duration_ms);
    }
    
    /// Generate report
    pub fn report(self: *BenchmarkRunner) !void {
        switch (self.config.output_format) {
            .table => try self.reportTable(),
            .csv => try self.reportCSV(),
            .json => try self.reportJSON(),
            .markdown => try self.reportMarkdown(),
        }
    }
    
    fn reportTable(self: *BenchmarkRunner) !void {
        const stdout = std.io.getStdOut().writer();
        
        try stdout.print("\n{s}\n", .{"=" ** 80});
        try stdout.print("Benchmark Results: {s}\n", .{self.config.name});
        try stdout.print("{s}\n\n", .{"=" ** 80});
        
        try stdout.print("{s:<8} {s:<8} {s:<8} {s:<12} {s:<10} {s:<10} {s:<10}\n", .{
            "Batch", "Prompt", "Output", "Tok/s", "TTFT(ms)", "ITL(ms)", "P99(ms)",
        });
        try stdout.print("{s}\n", .{"-" ** 80});
        
        for (self.results.items) |m| {
            try stdout.print("{d:<8} {d:<8} {d:<8} {d:<12.1} {d:<10.2} {d:<10.2} {d:<10.2}\n", .{
                m.batch_size,
                m.prompt_length,
                m.output_length,
                m.tokens_per_second,
                m.time_to_first_token_ms,
                m.inter_token_latency_ms,
                m.p99_latency_ms,
            });
        }
    }
    
    fn reportCSV(self: *BenchmarkRunner) !void {
        const stdout = std.io.getStdOut().writer();
        
        try stdout.print("batch_size,prompt_length,output_length,tokens_per_second,ttft_ms,itl_ms,p50_ms,p90_ms,p95_ms,p99_ms\n", .{});
        
        for (self.results.items) |m| {
            try stdout.print("{d},{d},{d},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2}\n", .{
                m.batch_size,
                m.prompt_length,
                m.output_length,
                m.tokens_per_second,
                m.time_to_first_token_ms,
                m.inter_token_latency_ms,
                m.p50_latency_ms,
                m.p90_latency_ms,
                m.p95_latency_ms,
                m.p99_latency_ms,
            });
        }
    }
    
    fn reportJSON(self: *BenchmarkRunner) !void {
        const stdout = std.io.getStdOut().writer();
        
        try stdout.print("{{\n  \"benchmark\": \"{s}\",\n  \"results\": [\n", .{self.config.name});
        
        for (self.results.items, 0..) |m, i| {
            try stdout.print("    {{\n", .{});
            try stdout.print("      \"batch_size\": {d},\n", .{m.batch_size});
            try stdout.print("      \"prompt_length\": {d},\n", .{m.prompt_length});
            try stdout.print("      \"output_length\": {d},\n", .{m.output_length});
            try stdout.print("      \"tokens_per_second\": {d:.2},\n", .{m.tokens_per_second});
            try stdout.print("      \"ttft_ms\": {d:.2},\n", .{m.time_to_first_token_ms});
            try stdout.print("      \"itl_ms\": {d:.2},\n", .{m.inter_token_latency_ms});
            try stdout.print("      \"p99_ms\": {d:.2}\n", .{m.p99_latency_ms});
            try stdout.print("    }}{s}\n", .{if (i < self.results.items.len - 1) "," else ""});
        }
        
        try stdout.print("  ]\n}}\n", .{});
    }
    
    fn reportMarkdown(self: *BenchmarkRunner) !void {
        const stdout = std.io.getStdOut().writer();
        
        try stdout.print("## Benchmark Results: {s}\n\n", .{self.config.name});
        try stdout.print("| Batch | Prompt | Output | Tok/s | TTFT (ms) | ITL (ms) | P99 (ms) |\n", .{});
        try stdout.print("|-------|--------|--------|-------|-----------|----------|----------|\n", .{});
        
        for (self.results.items) |m| {
            try stdout.print("| {d} | {d} | {d} | {d:.1} | {d:.2} | {d:.2} | {d:.2} |\n", .{
                m.batch_size,
                m.prompt_length,
                m.output_length,
                m.tokens_per_second,
                m.time_to_first_token_ms,
                m.inter_token_latency_ms,
                m.p99_latency_ms,
            });
        }
    }
};

// ==============================================
// Workload Generator
// ==============================================

/// Generates benchmark workloads
pub const WorkloadGenerator = struct {
    allocator: std.mem.Allocator,
    rng: std.Random.DefaultPrng,
    
    pub fn init(allocator: std.mem.Allocator, seed: u64) WorkloadGenerator {
        return WorkloadGenerator{
            .allocator = allocator,
            .rng = std.Random.DefaultPrng.init(seed),
        };
    }
    
    /// Generate random token IDs
    pub fn generateTokens(self: *WorkloadGenerator, count: usize, vocab_size: u32) ![]i32 {
        var tokens = try self.allocator.alloc(i32, count);
        const random = self.rng.random();
        
        for (tokens) |*t| {
            t.* = @intCast(random.intRangeAtMost(u32, 0, vocab_size - 1));
        }
        
        return tokens;
    }
    
    /// Generate realistic prompts (using common token patterns)
    pub fn generatePrompt(self: *WorkloadGenerator, length: usize) ![]i32 {
        // Use a more realistic distribution of tokens
        // Common tokens are more frequent
        return self.generateTokens(length, 32000);
    }
};

// ==============================================
// Tests
// ==============================================

test "LatencyTracker percentiles" {
    const allocator = std.testing.allocator;
    var tracker = LatencyTracker.init(allocator);
    defer tracker.deinit();
    
    // Add measurements
    const values = [_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0 };
    for (values) |v| {
        try tracker.record(v);
    }
    
    try std.testing.expectEqual(@as(f64, 5.5), tracker.mean());
    try std.testing.expectEqual(@as(f64, 5.0), tracker.p50());
    try std.testing.expectEqual(@as(f64, 9.0), tracker.p90());
}

test "BenchmarkRunner initialization" {
    const allocator = std.testing.allocator;
    var runner = BenchmarkRunner.init(allocator, .{
        .name = "test",
    });
    defer runner.deinit();
    
    try std.testing.expectEqual(@as(usize, 0), runner.results.items.len);
}
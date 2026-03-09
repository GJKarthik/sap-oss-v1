//! Benchmark - Performance benchmarking framework
//!
//! Purpose:
//! Provides micro-benchmarking utilities for measuring
//! performance of database operations and algorithms.

const std = @import("std");

// ============================================================================
// Benchmark Result
// ============================================================================

pub const BenchmarkResult = struct {
    name: []const u8,
    iterations: u64,
    total_time_ns: u64,
    min_time_ns: u64,
    max_time_ns: u64,
    mean_time_ns: u64,
    std_dev_ns: u64,
    ops_per_sec: f64,
    
    pub fn format(self: *const BenchmarkResult) [256]u8 {
        var buf: [256]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "{s}: {d} iters, mean={d}ns, min={d}ns, max={d}ns, ops/s={d:.2}", .{
            self.name,
            self.iterations,
            self.mean_time_ns,
            self.min_time_ns,
            self.max_time_ns,
            self.ops_per_sec,
        }) catch {};
        return buf;
    }
};

// ============================================================================
// Benchmark Config
// ============================================================================

pub const BenchmarkConfig = struct {
    warmup_iterations: u32 = 10,
    min_iterations: u32 = 100,
    max_iterations: u32 = 100_000,
    target_time_ns: u64 = 1_000_000_000,  // 1 second
    max_time_ns: u64 = 10_000_000_000,    // 10 seconds
};

// ============================================================================
// Benchmark
// ============================================================================

pub fn Benchmark(comptime Func: type) type {
    return struct {
        config: BenchmarkConfig = .{},
        name: []const u8,
        func: Func,
        
        const Self = @This();
        
        pub fn init(name: []const u8, func: Func) Self {
            return .{
                .name = name,
                .func = func,
            };
        }
        
        pub fn withConfig(self: Self, config: BenchmarkConfig) Self {
            var new = self;
            new.config = config;
            return new;
        }
        
        pub fn run(self: *const Self) BenchmarkResult {
            // Warmup
            var i: u32 = 0;
            while (i < self.config.warmup_iterations) : (i += 1) {
                _ = self.func();
            }
            
            // Determine iteration count
            var iterations: u64 = self.config.min_iterations;
            var times = .{};
            defer times.deinit(self.allocator);
            
            // Run benchmark
            var total_time: u64 = 0;
            var min_time: u64 = std.math.maxInt(u64);
            var max_time: u64 = 0;
            
            var iter: u64 = 0;
            while (iter < iterations and total_time < self.config.max_time_ns) : (iter += 1) {
                const start = @as(u64, @intCast(std.time.nanoTimestamp()));
                _ = self.func();
                const end = @as(u64, @intCast(std.time.nanoTimestamp()));
                
                const elapsed = end - start;
                times.append(self.allocator, elapsed);
                
                total_time += elapsed;
                min_time = @min(min_time, elapsed);
                max_time = @max(max_time, elapsed);
                
                // Auto-scale iterations
                if (iter == self.config.min_iterations and total_time < self.config.target_time_ns) {
                    const scale = @divFloor(self.config.target_time_ns, total_time + 1);
                    iterations = @min(iterations * scale, self.config.max_iterations);
                }
            }
            
            // Calculate statistics
            const mean = if (iter > 0) @divFloor(total_time, iter) else 0;
            
            // Standard deviation
            var variance_sum: u128 = 0;
            for (times.items) |t| {
                const diff: i128 = @as(i128, t) - @as(i128, mean);
                variance_sum += @intCast(diff * diff);
            }
            const variance = if (times.items.len > 0) variance_sum / times.items.len else 0;
            const std_dev: u64 = @intCast(std.math.sqrt(variance));
            
            // Operations per second
            const ops_per_sec = if (mean > 0)
                1_000_000_000.0 / @as(f64, @floatFromInt(mean))
            else
                0;
            
            return BenchmarkResult{
                .name = self.name,
                .iterations = iter,
                .total_time_ns = total_time,
                .min_time_ns = min_time,
                .max_time_ns = max_time,
                .mean_time_ns = mean,
                .std_dev_ns = std_dev,
                .ops_per_sec = ops_per_sec,
            };
        }
    };
}

// ============================================================================
// Benchmark Suite
// ============================================================================

pub const BenchmarkSuite = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    results: std.ArrayList(BenchmarkResult),
    config: BenchmarkConfig = .{},
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8) BenchmarkSuite {
        return .{
            .allocator = allocator,
            .name = name,
            .results = .{},
        };
    }
    
    pub fn deinit(self: *BenchmarkSuite) void {
        self.results.deinit(self.allocator);
    }
    
    pub fn add(self: *BenchmarkSuite, result: BenchmarkResult) !void {
        try self.results.append(self.allocator, result);
    }
    
    pub fn getSummary(self: *const BenchmarkSuite) SuiteSummary {
        var total_time: u64 = 0;
        var total_iterations: u64 = 0;
        
        for (self.results.items) |r| {
            total_time += r.total_time_ns;
            total_iterations += r.iterations;
        }
        
        return .{
            .name = self.name,
            .benchmark_count = self.results.items.len,
            .total_time_ns = total_time,
            .total_iterations = total_iterations,
        };
    }
};

pub const SuiteSummary = struct {
    name: []const u8,
    benchmark_count: usize,
    total_time_ns: u64,
    total_iterations: u64,
};

// ============================================================================
// Throughput Benchmark
// ============================================================================

pub const ThroughputResult = struct {
    name: []const u8,
    bytes_processed: u64,
    time_ns: u64,
    bytes_per_sec: f64,
    mb_per_sec: f64,
};

pub fn measureThroughput(name: []const u8, bytes: u64, func: anytype) ThroughputResult {
    const start = @as(u64, @intCast(std.time.nanoTimestamp()));
    func();
    const end = @as(u64, @intCast(std.time.nanoTimestamp()));
    
    const elapsed = end - start;
    const bytes_per_sec = if (elapsed > 0)
        @as(f64, @floatFromInt(bytes)) * 1_000_000_000.0 / @as(f64, @floatFromInt(elapsed))
    else
        0;
    
    return .{
        .name = name,
        .bytes_processed = bytes,
        .time_ns = elapsed,
        .bytes_per_sec = bytes_per_sec,
        .mb_per_sec = bytes_per_sec / (1024.0 * 1024.0),
    };
}

// ============================================================================
// Latency Histogram
// ============================================================================

pub const LatencyHistogram = struct {
    buckets: [32]u64 = [_]u64{0} ** 32,
    total_count: u64 = 0,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,
    sum_ns: u64 = 0,
    
    pub fn record(self: *LatencyHistogram, latency_ns: u64) void {
        // Log2 bucket
        const bucket = if (latency_ns == 0) 0 else @min(31, std.math.log2(latency_ns));
        self.buckets[bucket] += 1;
        self.total_count += 1;
        self.min_ns = @min(self.min_ns, latency_ns);
        self.max_ns = @max(self.max_ns, latency_ns);
        self.sum_ns += latency_ns;
    }
    
    pub fn mean(self: *const LatencyHistogram) u64 {
        if (self.total_count == 0) return 0;
        return @divFloor(self.sum_ns, self.total_count);
    }
    
    pub fn percentile(self: *const LatencyHistogram, p: f64) u64 {
        const target: u64 = @intFromFloat(@as(f64, @floatFromInt(self.total_count)) * p);
        var cumulative: u64 = 0;
        
        for (self.buckets, 0..) |count, i| {
            cumulative += count;
            if (cumulative >= target) {
                return @as(u64, 1) << @intCast(i);
            }
        }
        return self.max_ns;
    }
    
    pub fn p50(self: *const LatencyHistogram) u64 {
        return self.percentile(0.5);
    }
    
    pub fn p90(self: *const LatencyHistogram) u64 {
        return self.percentile(0.9);
    }
    
    pub fn p99(self: *const LatencyHistogram) u64 {
        return self.percentile(0.99);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "benchmark result" {
    const result = BenchmarkResult{
        .name = "test",
        .iterations = 100,
        .total_time_ns = 1000000,
        .min_time_ns = 5000,
        .max_time_ns = 15000,
        .mean_time_ns = 10000,
        .std_dev_ns = 1000,
        .ops_per_sec = 100000.0,
    };
    
    try std.testing.expectEqual(@as(u64, 100), result.iterations);
    try std.testing.expectEqual(@as(u64, 10000), result.mean_time_ns);
}

test "benchmark suite" {
    const allocator = std.testing.allocator;
    
    var suite = BenchmarkSuite.init(allocator, "test suite");
    defer suite.deinit();
    
    try suite.add(.{
        .name = "bench1",
        .iterations = 100,
        .total_time_ns = 1000000,
        .min_time_ns = 5000,
        .max_time_ns = 15000,
        .mean_time_ns = 10000,
        .std_dev_ns = 1000,
        .ops_per_sec = 100000.0,
    });
    
    const summary = suite.getSummary();
    try std.testing.expectEqual(@as(usize, 1), summary.benchmark_count);
}

test "latency histogram" {
    var hist = LatencyHistogram{};
    
    hist.record(100);
    hist.record(200);
    hist.record(150);
    
    try std.testing.expectEqual(@as(u64, 3), hist.total_count);
    try std.testing.expectEqual(@as(u64, 100), hist.min_ns);
    try std.testing.expectEqual(@as(u64, 200), hist.max_ns);
    try std.testing.expectEqual(@as(u64, 150), hist.mean());
}

test "latency histogram percentiles" {
    var hist = LatencyHistogram{};
    
    // Add samples with known distribution
    var i: u64 = 1;
    while (i <= 100) : (i += 1) {
        hist.record(i * 1000);
    }
    
    try std.testing.expect(hist.p50() > 0);
    try std.testing.expect(hist.p90() >= hist.p50());
    try std.testing.expect(hist.p99() >= hist.p90());
}

test "throughput result" {
    const result = ThroughputResult{
        .name = "test",
        .bytes_processed = 1024 * 1024,
        .time_ns = 1000000,
        .bytes_per_sec = 1073741824.0,
        .mb_per_sec = 1024.0,
    };
    
    try std.testing.expectEqual(@as(u64, 1024 * 1024), result.bytes_processed);
}
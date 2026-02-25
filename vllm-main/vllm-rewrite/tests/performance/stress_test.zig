//! Stress Testing Harness
//!
//! Load and stress testing for the vLLM system.
//! Validates system behavior under heavy load.
//!
//! Features:
//! - Concurrent request generation
//! - Configurable load patterns
//! - Performance metrics collection
//! - Resource monitoring

const std = @import("std");

// ==============================================
// Stress Test Configuration
// ==============================================

pub const StressTestConfig = struct {
    /// Number of concurrent workers
    num_workers: u32 = 10,
    
    /// Requests per second target
    target_rps: u32 = 100,
    
    /// Test duration in seconds
    duration_seconds: u64 = 60,
    
    /// Warmup period in seconds
    warmup_seconds: u64 = 10,
    
    /// Maximum concurrent requests
    max_concurrent: u32 = 1000,
    
    /// Request timeout in milliseconds
    request_timeout_ms: u64 = 30000,
    
    /// Server host
    host: []const u8 = "localhost",
    
    /// Server port
    port: u16 = 8000,
    
    /// Enable detailed logging
    verbose: bool = false,
};

// ==============================================
// Load Patterns
// ==============================================

pub const LoadPattern = enum {
    /// Constant rate
    constant,
    
    /// Linear increase over time
    ramp_up,
    
    /// Periodic spikes
    spike,
    
    /// Random within bounds
    random,
    
    /// Step function
    step,
    
    pub fn getRps(self: LoadPattern, elapsed_seconds: u64, config: StressTestConfig) u32 {
        return switch (self) {
            .constant => config.target_rps,
            .ramp_up => @as(u32, @intCast(@min(
                config.target_rps * elapsed_seconds / config.duration_seconds + 1,
                config.target_rps,
            ))),
            .spike => blk: {
                // Spike every 10 seconds
                const in_spike = (elapsed_seconds % 20) >= 15;
                break :blk if (in_spike) config.target_rps * 3 else config.target_rps;
            },
            .random => @as(u32, @intCast(config.target_rps / 2 + (std.crypto.random.int(u32) % (config.target_rps / 2 + 1)))),
            .step => blk: {
                const step = elapsed_seconds * 4 / config.duration_seconds;
                break :blk @as(u32, @intCast((step + 1) * config.target_rps / 4));
            },
        };
    }
};

// ==============================================
// Request Generator
// ==============================================

pub const RequestGenerator = struct {
    allocator: std.mem.Allocator,
    prompts: []const []const u8,
    current_index: std.atomic.Value(usize),
    
    const DEFAULT_PROMPTS = [_][]const u8{
        "What is the capital of France?",
        "Explain quantum computing in simple terms.",
        "Write a haiku about programming.",
        "What is 2 + 2?",
        "Describe the color blue.",
        "List three types of fruits.",
        "What is machine learning?",
        "Hello, how are you?",
    };
    
    pub fn init(allocator: std.mem.Allocator) RequestGenerator {
        return RequestGenerator{
            .allocator = allocator,
            .prompts = &DEFAULT_PROMPTS,
            .current_index = std.atomic.Value(usize).init(0),
        };
    }
    
    pub fn generateRequest(self: *RequestGenerator) ![]const u8 {
        const index = self.current_index.fetchAdd(1, .monotonic) % self.prompts.len;
        const prompt = self.prompts[index];
        
        return try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "model": "test-model",
            \\  "prompt": "{s}",
            \\  "max_tokens": 50
            \\}}
        , .{prompt});
    }
};

// ==============================================
// Performance Metrics
// ==============================================

pub const PerformanceMetrics = struct {
    allocator: std.mem.Allocator,
    
    // Request counts
    total_requests: std.atomic.Value(u64),
    successful_requests: std.atomic.Value(u64),
    failed_requests: std.atomic.Value(u64),
    timeout_requests: std.atomic.Value(u64),
    
    // Latency tracking (in microseconds)
    latencies: std.ArrayList(u64),
    latency_mutex: std.Thread.Mutex,
    
    // Throughput tracking
    start_time: i64,
    tokens_generated: std.atomic.Value(u64),
    
    pub fn init(allocator: std.mem.Allocator) PerformanceMetrics {
        return PerformanceMetrics{
            .allocator = allocator,
            .total_requests = std.atomic.Value(u64).init(0),
            .successful_requests = std.atomic.Value(u64).init(0),
            .failed_requests = std.atomic.Value(u64).init(0),
            .timeout_requests = std.atomic.Value(u64).init(0),
            .latencies = std.ArrayList(u64).init(allocator),
            .latency_mutex = .{},
            .start_time = std.time.milliTimestamp(),
            .tokens_generated = std.atomic.Value(u64).init(0),
        };
    }
    
    pub fn deinit(self: *PerformanceMetrics) void {
        self.latencies.deinit();
    }
    
    pub fn recordRequest(self: *PerformanceMetrics, success: bool, latency_us: u64, tokens: u64) void {
        _ = self.total_requests.fetchAdd(1, .monotonic);
        
        if (success) {
            _ = self.successful_requests.fetchAdd(1, .monotonic);
        } else {
            _ = self.failed_requests.fetchAdd(1, .monotonic);
        }
        
        _ = self.tokens_generated.fetchAdd(tokens, .monotonic);
        
        self.latency_mutex.lock();
        defer self.latency_mutex.unlock();
        self.latencies.append(latency_us) catch {};
    }
    
    pub fn recordTimeout(self: *PerformanceMetrics) void {
        _ = self.total_requests.fetchAdd(1, .monotonic);
        _ = self.timeout_requests.fetchAdd(1, .monotonic);
    }
    
    pub fn getReport(self: *PerformanceMetrics) PerformanceReport {
        self.latency_mutex.lock();
        defer self.latency_mutex.unlock();
        
        const elapsed_ms = @as(u64, @intCast(std.time.milliTimestamp() - self.start_time));
        const elapsed_seconds = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
        
        const total = self.total_requests.load(.monotonic);
        const successful = self.successful_requests.load(.monotonic);
        const tokens = self.tokens_generated.load(.monotonic);
        
        // Calculate latency percentiles
        var sorted_latencies = self.latencies.clone() catch return PerformanceReport{};
        defer sorted_latencies.deinit();
        std.sort.insertion(u64, sorted_latencies.items, {}, std.sort.asc(u64));
        
        const p50 = if (sorted_latencies.items.len > 0)
            sorted_latencies.items[sorted_latencies.items.len / 2]
        else
            0;
        
        const p95 = if (sorted_latencies.items.len > 0)
            sorted_latencies.items[sorted_latencies.items.len * 95 / 100]
        else
            0;
        
        const p99 = if (sorted_latencies.items.len > 0)
            sorted_latencies.items[sorted_latencies.items.len * 99 / 100]
        else
            0;
        
        var sum: u64 = 0;
        for (sorted_latencies.items) |l| sum += l;
        const avg = if (sorted_latencies.items.len > 0)
            sum / sorted_latencies.items.len
        else
            0;
        
        return PerformanceReport{
            .total_requests = total,
            .successful_requests = successful,
            .failed_requests = self.failed_requests.load(.monotonic),
            .timeout_requests = self.timeout_requests.load(.monotonic),
            .requests_per_second = if (elapsed_seconds > 0)
                @as(f64, @floatFromInt(total)) / elapsed_seconds
            else
                0,
            .tokens_per_second = if (elapsed_seconds > 0)
                @as(f64, @floatFromInt(tokens)) / elapsed_seconds
            else
                0,
            .latency_avg_ms = @as(f64, @floatFromInt(avg)) / 1000.0,
            .latency_p50_ms = @as(f64, @floatFromInt(p50)) / 1000.0,
            .latency_p95_ms = @as(f64, @floatFromInt(p95)) / 1000.0,
            .latency_p99_ms = @as(f64, @floatFromInt(p99)) / 1000.0,
            .success_rate = if (total > 0)
                @as(f64, @floatFromInt(successful)) / @as(f64, @floatFromInt(total)) * 100.0
            else
                0,
            .duration_seconds = elapsed_seconds,
        };
    }
};

pub const PerformanceReport = struct {
    total_requests: u64 = 0,
    successful_requests: u64 = 0,
    failed_requests: u64 = 0,
    timeout_requests: u64 = 0,
    requests_per_second: f64 = 0,
    tokens_per_second: f64 = 0,
    latency_avg_ms: f64 = 0,
    latency_p50_ms: f64 = 0,
    latency_p95_ms: f64 = 0,
    latency_p99_ms: f64 = 0,
    success_rate: f64 = 0,
    duration_seconds: f64 = 0,
    
    pub fn print(self: PerformanceReport) void {
        std.debug.print("\n╔════════════════════════════════════════════╗\n", .{});
        std.debug.print("║          STRESS TEST REPORT                  ║\n", .{});
        std.debug.print("╚════════════════════════════════════════════╝\n\n", .{});
        
        std.debug.print("Duration: {d:.1}s\n\n", .{self.duration_seconds});
        
        std.debug.print("📊 Request Statistics:\n", .{});
        std.debug.print("  Total:      {d}\n", .{self.total_requests});
        std.debug.print("  Successful: {d}\n", .{self.successful_requests});
        std.debug.print("  Failed:     {d}\n", .{self.failed_requests});
        std.debug.print("  Timeouts:   {d}\n", .{self.timeout_requests});
        std.debug.print("  Success %:  {d:.2}%\n\n", .{self.success_rate});
        
        std.debug.print("⚡ Throughput:\n", .{});
        std.debug.print("  Requests/s: {d:.2}\n", .{self.requests_per_second});
        std.debug.print("  Tokens/s:   {d:.2}\n\n", .{self.tokens_per_second});
        
        std.debug.print("⏱  Latency:\n", .{});
        std.debug.print("  Average:    {d:.2}ms\n", .{self.latency_avg_ms});
        std.debug.print("  P50:        {d:.2}ms\n", .{self.latency_p50_ms});
        std.debug.print("  P95:        {d:.2}ms\n", .{self.latency_p95_ms});
        std.debug.print("  P99:        {d:.2}ms\n", .{self.latency_p99_ms});
        
        std.debug.print("\n────────────────────────────────────────────\n", .{});
    }
};

// ==============================================
// Stress Test Runner
// ==============================================

pub const StressTestRunner = struct {
    allocator: std.mem.Allocator,
    config: StressTestConfig,
    metrics: PerformanceMetrics,
    generator: RequestGenerator,
    running: std.atomic.Value(bool),
    
    pub fn init(allocator: std.mem.Allocator, config: StressTestConfig) StressTestRunner {
        return StressTestRunner{
            .allocator = allocator,
            .config = config,
            .metrics = PerformanceMetrics.init(allocator),
            .generator = RequestGenerator.init(allocator),
            .running = std.atomic.Value(bool).init(false),
        };
    }
    
    pub fn deinit(self: *StressTestRunner) void {
        self.metrics.deinit();
    }
    
    pub fn run(self: *StressTestRunner, pattern: LoadPattern) !PerformanceReport {
        self.running.store(true, .monotonic);
        self.metrics.start_time = std.time.milliTimestamp();
        
        std.debug.print("Starting stress test...\n", .{});
        std.debug.print("  Workers:    {d}\n", .{self.config.num_workers});
        std.debug.print("  Target RPS: {d}\n", .{self.config.target_rps});
        std.debug.print("  Duration:   {d}s\n", .{self.config.duration_seconds});
        std.debug.print("  Warmup:     {d}s\n\n", .{self.config.warmup_seconds});
        
        // Spawn worker threads
        var workers = std.ArrayList(std.Thread).init(self.allocator);
        defer workers.deinit();
        
        for (0..self.config.num_workers) |_| {
            const thread = try std.Thread.spawn(.{}, workerThread, .{ self, pattern });
            try workers.append(thread);
        }
        
        // Wait for duration
        const total_duration = self.config.warmup_seconds + self.config.duration_seconds;
        std.time.sleep(total_duration * std.time.ns_per_s);
        
        // Stop workers
        self.running.store(false, .monotonic);
        
        for (workers.items) |thread| {
            thread.join();
        }
        
        const report = self.metrics.getReport();
        report.print();
        
        return report;
    }
    
    fn workerThread(self: *StressTestRunner, pattern: LoadPattern) void {
        while (self.running.load(.monotonic)) {
            const elapsed = @as(u64, @intCast(@divFloor(
                std.time.milliTimestamp() - self.metrics.start_time,
                1000,
            )));
            
            const target_rps = pattern.getRps(elapsed, self.config);
            const delay_ns = if (target_rps > 0)
                @as(u64, @intCast(std.time.ns_per_s / target_rps / self.config.num_workers))
            else
                std.time.ns_per_s;
            
            // Send request
            self.sendRequest();
            
            // Rate limit
            std.time.sleep(delay_ns);
        }
    }
    
    fn sendRequest(self: *StressTestRunner) void {
        const start = std.time.microTimestamp();
        
        // Simulate request (would be actual HTTP call)
        std.time.sleep(std.time.ns_per_ms * 10);  // 10ms simulated latency
        
        const latency = @as(u64, @intCast(std.time.microTimestamp() - start));
        self.metrics.recordRequest(true, latency, 10);
    }
};

// ==============================================
// Memory Leak Detector
// ==============================================

pub const MemoryLeakDetector = struct {
    allocator: std.mem.Allocator,
    baseline_memory: usize,
    samples: std.ArrayList(MemorySample),
    
    pub const MemorySample = struct {
        timestamp_ms: i64,
        allocated_bytes: usize,
        peak_bytes: usize,
    };
    
    pub fn init(allocator: std.mem.Allocator) MemoryLeakDetector {
        return MemoryLeakDetector{
            .allocator = allocator,
            .baseline_memory = 0,
            .samples = std.ArrayList(MemorySample).init(allocator),
        };
    }
    
    pub fn deinit(self: *MemoryLeakDetector) void {
        self.samples.deinit();
    }
    
    pub fn setBaseline(self: *MemoryLeakDetector, bytes: usize) void {
        self.baseline_memory = bytes;
    }
    
    pub fn recordSample(self: *MemoryLeakDetector, allocated: usize, peak: usize) !void {
        try self.samples.append(MemorySample{
            .timestamp_ms = std.time.milliTimestamp(),
            .allocated_bytes = allocated,
            .peak_bytes = peak,
        });
    }
    
    pub fn analyze(self: *MemoryLeakDetector) LeakAnalysis {
        if (self.samples.items.len < 2) {
            return LeakAnalysis{ .likely_leak = false };
        }
        
        const first = self.samples.items[0];
        const last = self.samples.items[self.samples.items.len - 1];
        
        const growth = @as(i64, @intCast(last.allocated_bytes)) - @as(i64, @intCast(first.allocated_bytes));
        const duration_ms = last.timestamp_ms - first.timestamp_ms;
        
        const growth_rate = if (duration_ms > 0)
            @as(f64, @floatFromInt(growth)) / @as(f64, @floatFromInt(duration_ms)) * 1000.0
        else
            0;
        
        // Leak detection heuristics
        const likely_leak = growth > 0 and
            @as(usize, @intCast(@max(growth, 0))) > self.baseline_memory / 10 and
            growth_rate > 100;  // More than 100 bytes/sec growth
        
        var max_memory: usize = 0;
        for (self.samples.items) |sample| {
            max_memory = @max(max_memory, sample.peak_bytes);
        }
        
        return LeakAnalysis{
            .likely_leak = likely_leak,
            .memory_growth_bytes = growth,
            .growth_rate_per_second = growth_rate,
            .peak_memory_bytes = max_memory,
            .samples_collected = self.samples.items.len,
        };
    }
};

pub const LeakAnalysis = struct {
    likely_leak: bool = false,
    memory_growth_bytes: i64 = 0,
    growth_rate_per_second: f64 = 0,
    peak_memory_bytes: usize = 0,
    samples_collected: usize = 0,
    
    pub fn print(self: LeakAnalysis) void {
        std.debug.print("\n╔════════════════════════════════════════════╗\n", .{});
        std.debug.print("║          MEMORY ANALYSIS REPORT              ║\n", .{});
        std.debug.print("╚════════════════════════════════════════════╝\n\n", .{});
        
        std.debug.print("Samples collected: {d}\n", .{self.samples_collected});
        std.debug.print("Memory growth:     {d} bytes\n", .{self.memory_growth_bytes});
        std.debug.print("Growth rate:       {d:.2} bytes/s\n", .{self.growth_rate_per_second});
        std.debug.print("Peak memory:       {d} bytes\n", .{self.peak_memory_bytes});
        std.debug.print("Likely leak:       {s}\n", .{if (self.likely_leak) "YES ⚠️" else "NO ✓"});
        
        std.debug.print("\n────────────────────────────────────────────\n", .{});
    }
};

// ==============================================
// Performance Regression Tests
// ==============================================

pub const RegressionTest = struct {
    name: []const u8,
    baseline_ms: f64,
    tolerance_percent: f64,
    test_func: *const fn (allocator: std.mem.Allocator) f64,
    
    pub fn run(self: *const RegressionTest, allocator: std.mem.Allocator) RegressionResult {
        const actual = self.test_func(allocator);
        const threshold = self.baseline_ms * (1.0 + self.tolerance_percent / 100.0);
        const passed = actual <= threshold;
        
        return RegressionResult{
            .name = self.name,
            .baseline_ms = self.baseline_ms,
            .actual_ms = actual,
            .threshold_ms = threshold,
            .passed = passed,
            .regression_percent = (actual - self.baseline_ms) / self.baseline_ms * 100.0,
        };
    }
};

pub const RegressionResult = struct {
    name: []const u8,
    baseline_ms: f64,
    actual_ms: f64,
    threshold_ms: f64,
    passed: bool,
    regression_percent: f64,
    
    pub fn print(self: RegressionResult) void {
        const status = if (self.passed) "\x1b[32m✓ PASS\x1b[0m" else "\x1b[31m✗ FAIL\x1b[0m";
        std.debug.print("{s} {s}\n", .{ status, self.name });
        std.debug.print("    Baseline:   {d:.2}ms\n", .{self.baseline_ms});
        std.debug.print("    Actual:     {d:.2}ms\n", .{self.actual_ms});
        std.debug.print("    Threshold:  {d:.2}ms\n", .{self.threshold_ms});
        std.debug.print("    Regression: {d:+.1}%\n\n", .{self.regression_percent});
    }
};

pub const RegressionTestSuite = struct {
    allocator: std.mem.Allocator,
    tests: std.ArrayList(RegressionTest),
    
    pub fn init(allocator: std.mem.Allocator) RegressionTestSuite {
        return RegressionTestSuite{
            .allocator = allocator,
            .tests = std.ArrayList(RegressionTest).init(allocator),
        };
    }
    
    pub fn deinit(self: *RegressionTestSuite) void {
        self.tests.deinit();
    }
    
    pub fn addTest(self: *RegressionTestSuite, test_def: RegressionTest) !void {
        try self.tests.append(test_def);
    }
    
    pub fn runAll(self: *RegressionTestSuite) !RegressionSuiteResult {
        var results = std.ArrayList(RegressionResult).init(self.allocator);
        
        std.debug.print("\n╔════════════════════════════════════════════╗\n", .{});
        std.debug.print("║       PERFORMANCE REGRESSION TESTS           ║\n", .{});
        std.debug.print("╚════════════════════════════════════════════╝\n\n", .{});
        
        var passed: u32 = 0;
        var failed: u32 = 0;
        
        for (self.tests.items) |test_def| {
            const result = test_def.run(self.allocator);
            result.print();
            
            if (result.passed) {
                passed += 1;
            } else {
                failed += 1;
            }
            
            try results.append(result);
        }
        
        std.debug.print("────────────────────────────────────────────\n", .{});
        std.debug.print("Results: ", .{});
        if (passed > 0) std.debug.print("\x1b[32m{d} passed\x1b[0m ", .{passed});
        if (failed > 0) std.debug.print("\x1b[31m{d} failed\x1b[0m ", .{failed});
        std.debug.print("({d} total)\n", .{passed + failed});
        std.debug.print("────────────────────────────────────────────\n\n", .{});
        
        return RegressionSuiteResult{
            .results = try results.toOwnedSlice(),
            .passed = passed,
            .failed = failed,
        };
    }
};

pub const RegressionSuiteResult = struct {
    results: []RegressionResult,
    passed: u32,
    failed: u32,
    
    pub fn success(self: RegressionSuiteResult) bool {
        return self.failed == 0;
    }
};

// ==============================================
// Example Tests
// ==============================================

fn benchmarkTokenization(allocator: std.mem.Allocator) f64 {
    _ = allocator;
    const start = std.time.microTimestamp();
    
    // Simulate tokenization work
    var sum: u64 = 0;
    for (0..10000) |i| {
        sum += i;
    }
    std.mem.doNotOptimizeAway(&sum);
    
    const elapsed_us = std.time.microTimestamp() - start;
    return @as(f64, @floatFromInt(elapsed_us)) / 1000.0;
}

fn benchmarkSampling(allocator: std.mem.Allocator) f64 {
    _ = allocator;
    const start = std.time.microTimestamp();
    
    // Simulate sampling work
    var rng = std.rand.DefaultPrng.init(42);
    var sum: f64 = 0;
    for (0..1000) |_| {
        sum += rng.random().float(f64);
    }
    std.mem.doNotOptimizeAway(&sum);
    
    const elapsed_us = std.time.microTimestamp() - start;
    return @as(f64, @floatFromInt(elapsed_us)) / 1000.0;
}

// ==============================================
// Tests
// ==============================================

test "PerformanceMetrics recording" {
    const allocator = std.testing.allocator;
    var metrics = PerformanceMetrics.init(allocator);
    defer metrics.deinit();
    
    metrics.recordRequest(true, 1000, 10);
    metrics.recordRequest(true, 2000, 20);
    metrics.recordRequest(false, 500, 0);
    
    try std.testing.expectEqual(@as(u64, 3), metrics.total_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 2), metrics.successful_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), metrics.failed_requests.load(.monotonic));
}

test "LoadPattern.constant" {
    const config = StressTestConfig{ .target_rps = 100 };
    try std.testing.expectEqual(@as(u32, 100), LoadPattern.constant.getRps(0, config));
    try std.testing.expectEqual(@as(u32, 100), LoadPattern.constant.getRps(30, config));
}

test "MemoryLeakDetector analysis" {
    const allocator = std.testing.allocator;
    var detector = MemoryLeakDetector.init(allocator);
    defer detector.deinit();
    
    detector.setBaseline(1000);
    try detector.recordSample(1000, 1000);
    try detector.recordSample(1000, 1000);
    
    const analysis = detector.analyze();
    try std.testing.expect(!analysis.likely_leak);
}
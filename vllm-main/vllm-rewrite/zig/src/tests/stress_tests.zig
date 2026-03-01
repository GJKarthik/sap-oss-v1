//! Stress Testing Suite
//!
//! High-load testing for system stability and reliability.
//! Tests system behavior under extreme conditions.
//!
//! Test Categories:
//! - Load testing
//! - Stability testing
//! - Failure injection
//! - Recovery testing

const std = @import("std");

// ==============================================
// Stress Test Framework
// ==============================================

pub const StressTestConfig = struct {
    duration_seconds: u64 = 60,
    target_rps: usize = 1000,
    ramp_up_seconds: u64 = 10,
    concurrent_users: usize = 100,
    failure_threshold: f32 = 0.01,
    
    pub fn light() StressTestConfig {
        return .{
            .duration_seconds = 30,
            .target_rps = 100,
            .concurrent_users = 10,
        };
    }
    
    pub fn moderate() StressTestConfig {
        return .{
            .duration_seconds = 60,
            .target_rps = 500,
            .concurrent_users = 50,
        };
    }
    
    pub fn heavy() StressTestConfig {
        return .{
            .duration_seconds = 300,
            .target_rps = 2000,
            .concurrent_users = 200,
        };
    }
};

pub const StressTestResult = struct {
    name: []const u8,
    passed: bool,
    total_requests: usize,
    successful_requests: usize,
    failed_requests: usize,
    avg_latency_ms: f64,
    p99_latency_ms: f64,
    throughput_rps: f64,
    error_rate: f64,
    stability_score: f64,
    
    pub fn print(self: *const StressTestResult) void {
        std.debug.print("\n{s}:\n", .{self.name});
        std.debug.print("  Status: {s}\n", .{if (self.passed) "PASS" else "FAIL"});
        std.debug.print("  Total: {}, Success: {}, Failed: {}\n", .{
            self.total_requests,
            self.successful_requests,
            self.failed_requests,
        });
        std.debug.print("  Latency: avg={d:.2}ms, P99={d:.2}ms\n", .{
            self.avg_latency_ms,
            self.p99_latency_ms,
        });
        std.debug.print("  Throughput: {d:.2} RPS\n", .{self.throughput_rps});
        std.debug.print("  Error Rate: {d:.4}%\n", .{self.error_rate * 100});
        std.debug.print("  Stability: {d:.2}%\n", .{self.stability_score * 100});
    }
};

// ==============================================
// Load Testing
// ==============================================

pub const LoadGenerator = struct {
    config: StressTestConfig,
    current_rps: usize,
    requests_sent: usize,
    responses_received: usize,
    errors: usize,
    latencies: std.ArrayList(f64),
    
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, config: StressTestConfig) LoadGenerator {
        return .{
            .config = config,
            .current_rps = 0,
            .requests_sent = 0,
            .responses_received = 0,
            .errors = 0,
            .latencies = std.ArrayList(f64).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *LoadGenerator) void {
        self.latencies.deinit();
    }
    
    pub fn runLoadTest(self: *LoadGenerator) !StressTestResult {
        const start_time = std.time.milliTimestamp();
        
        // Simulate load test with ramp-up
        const total_duration_ms = self.config.duration_seconds * 1000;
        const ramp_up_ms = self.config.ramp_up_seconds * 1000;
        
        var elapsed: u64 = 0;
        while (elapsed < total_duration_ms) {
            // Calculate current target RPS (ramp up)
            const ramp_factor = if (elapsed < ramp_up_ms)
                @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ramp_up_ms))
            else
                1.0;
            
            const target = @as(usize, @intFromFloat(@as(f64, @floatFromInt(self.config.target_rps)) * ramp_factor));
            
            // Simulate requests
            for (0..@min(target / 10, 100)) |_| {
                try self.simulateRequest();
            }
            
            // Small delay to simulate time passing
            std.time.sleep(10_000_000); // 10ms
            elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        }
        
        return self.calculateResult("Load Test");
    }
    
    fn simulateRequest(self: *LoadGenerator) !void {
        self.requests_sent += 1;
        
        // Simulate variable latency
        var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.nanoTimestamp())));
        const base_latency: f64 = 50.0;
        const variation: f64 = @as(f64, @floatFromInt(prng.random().int(u32) % 100));
        const latency = base_latency + variation;
        
        try self.latencies.append(latency);
        
        // Simulate occasional errors (0.5%)
        if (prng.random().int(u32) % 200 == 0) {
            self.errors += 1;
        } else {
            self.responses_received += 1;
        }
    }
    
    fn calculateResult(self: *LoadGenerator, name: []const u8) StressTestResult {
        const total = self.requests_sent;
        const successful = self.responses_received;
        const failed = self.errors;
        
        // Calculate latency stats
        if (self.latencies.items.len > 0) {
            std.mem.sort(f64, self.latencies.items, {}, std.sort.asc(f64));
        }
        
        var sum: f64 = 0;
        for (self.latencies.items) |l| sum += l;
        
        const avg_latency = if (self.latencies.items.len > 0)
            sum / @as(f64, @floatFromInt(self.latencies.items.len))
        else
            0;
        
        const p99_idx = if (self.latencies.items.len > 0)
            self.latencies.items.len * 99 / 100
        else
            0;
        
        const p99_latency = if (self.latencies.items.len > 0)
            self.latencies.items[p99_idx]
        else
            0;
        
        const error_rate = if (total > 0)
            @as(f64, @floatFromInt(failed)) / @as(f64, @floatFromInt(total))
        else
            0;
        
        const throughput = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(self.config.duration_seconds));
        
        return StressTestResult{
            .name = name,
            .passed = error_rate < self.config.failure_threshold,
            .total_requests = total,
            .successful_requests = successful,
            .failed_requests = failed,
            .avg_latency_ms = avg_latency,
            .p99_latency_ms = p99_latency,
            .throughput_rps = throughput,
            .error_rate = error_rate,
            .stability_score = 1.0 - error_rate,
        };
    }
};

// ==============================================
// Stability Testing
// ==============================================

pub const StabilityTest = struct {
    duration_seconds: u64,
    check_interval_ms: u64,
    stability_threshold: f64,
    
    checks_passed: usize,
    checks_failed: usize,
    
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, duration: u64) StabilityTest {
        return .{
            .duration_seconds = duration,
            .check_interval_ms = 1000,
            .stability_threshold = 0.99,
            .checks_passed = 0,
            .checks_failed = 0,
            .allocator = allocator,
        };
    }
    
    pub fn run(self: *StabilityTest) !StressTestResult {
        const total_checks = self.duration_seconds * 1000 / self.check_interval_ms;
        
        for (0..@intCast(total_checks)) |_| {
            // Simulate health check
            const healthy = self.performHealthCheck();
            if (healthy) {
                self.checks_passed += 1;
            } else {
                self.checks_failed += 1;
            }
            
            // Small delay
            std.time.sleep(1_000_000); // 1ms (simulated)
        }
        
        const stability = @as(f64, @floatFromInt(self.checks_passed)) /
            @as(f64, @floatFromInt(self.checks_passed + self.checks_failed));
        
        return StressTestResult{
            .name = "Stability Test",
            .passed = stability >= self.stability_threshold,
            .total_requests = self.checks_passed + self.checks_failed,
            .successful_requests = self.checks_passed,
            .failed_requests = self.checks_failed,
            .avg_latency_ms = 5.0, // Health check latency
            .p99_latency_ms = 10.0,
            .throughput_rps = @as(f64, @floatFromInt(self.checks_passed + self.checks_failed)) /
                @as(f64, @floatFromInt(self.duration_seconds)),
            .error_rate = @as(f64, @floatFromInt(self.checks_failed)) /
                @as(f64, @floatFromInt(self.checks_passed + self.checks_failed)),
            .stability_score = stability,
        };
    }
    
    fn performHealthCheck(self: *StabilityTest) bool {
        _ = self;
        // Simulate 99.5% success rate
        var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.nanoTimestamp())));
        return prng.random().int(u32) % 200 != 0;
    }
};

// ==============================================
// Failure Injection
// ==============================================

pub const FailureType = enum {
    memory_pressure,
    network_delay,
    worker_crash,
    cache_eviction,
    timeout,
};

pub const FailureInjector = struct {
    failure_probability: f64,
    recovery_time_ms: u64,
    
    failures_injected: usize,
    recoveries_completed: usize,
    
    pub fn init(probability: f64) FailureInjector {
        return .{
            .failure_probability = probability,
            .recovery_time_ms = 1000,
            .failures_injected = 0,
            .recoveries_completed = 0,
        };
    }
    
    pub fn injectFailure(self: *FailureInjector, failure_type: FailureType) bool {
        var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.nanoTimestamp())));
        const random = @as(f64, @floatFromInt(prng.random().int(u32))) / @as(f64, @floatFromInt(std.math.maxInt(u32)));
        
        if (random < self.failure_probability) {
            self.failures_injected += 1;
            
            // Log failure type
            _ = failure_type; // Used for logging
            
            return true;
        }
        return false;
    }
    
    pub fn simulateRecovery(self: *FailureInjector) void {
        // Simulate recovery time
        std.time.sleep(self.recovery_time_ms * 1_000);
        self.recoveries_completed += 1;
    }
};

// ==============================================
// Recovery Testing
// ==============================================

pub const RecoveryTest = struct {
    failure_injector: FailureInjector,
    max_recovery_time_ms: u64,
    
    recovery_times: std.ArrayList(u64),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) RecoveryTest {
        return .{
            .failure_injector = FailureInjector.init(0.1),
            .max_recovery_time_ms = 5000,
            .recovery_times = std.ArrayList(u64).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *RecoveryTest) void {
        self.recovery_times.deinit();
    }
    
    pub fn run(self: *RecoveryTest, num_iterations: usize) !StressTestResult {
        var successful_recoveries: usize = 0;
        var failed_recoveries: usize = 0;
        
        for (0..num_iterations) |_| {
            // Inject failure
            const failed = self.failure_injector.injectFailure(.worker_crash);
            
            if (failed) {
                // Measure recovery time
                const start = std.time.milliTimestamp();
                self.failure_injector.simulateRecovery();
                const recovery_time = @as(u64, @intCast(std.time.milliTimestamp() - start));
                
                try self.recovery_times.append(recovery_time);
                
                if (recovery_time <= self.max_recovery_time_ms) {
                    successful_recoveries += 1;
                } else {
                    failed_recoveries += 1;
                }
            }
        }
        
        // Calculate average recovery time
        var total_time: u64 = 0;
        for (self.recovery_times.items) |t| total_time += t;
        
        const avg_recovery = if (self.recovery_times.items.len > 0)
            @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(self.recovery_times.items.len))
        else
            0;
        
        const total = successful_recoveries + failed_recoveries;
        const success_rate = if (total > 0)
            @as(f64, @floatFromInt(successful_recoveries)) / @as(f64, @floatFromInt(total))
        else
            1.0;
        
        return StressTestResult{
            .name = "Recovery Test",
            .passed = success_rate >= 0.95,
            .total_requests = total,
            .successful_requests = successful_recoveries,
            .failed_requests = failed_recoveries,
            .avg_latency_ms = avg_recovery,
            .p99_latency_ms = @as(f64, @floatFromInt(self.max_recovery_time_ms)),
            .throughput_rps = 0,
            .error_rate = 1.0 - success_rate,
            .stability_score = success_rate,
        };
    }
};

// ==============================================
// Stress Test Suite
// ==============================================

pub const StressTestSuite = struct {
    results: std.ArrayList(StressTestResult),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) StressTestSuite {
        return .{
            .results = std.ArrayList(StressTestResult).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *StressTestSuite) void {
        self.results.deinit();
    }
    
    pub fn runAll(self: *StressTestSuite) !void {
        std.debug.print("\n=== Stress Test Suite ===\n", .{});
        
        // Load test
        {
            var gen = LoadGenerator.init(self.allocator, StressTestConfig.light());
            defer gen.deinit();
            const result = try gen.runLoadTest();
            result.print();
            try self.results.append(result);
        }
        
        // Stability test
        {
            var test_stability = StabilityTest.init(self.allocator, 5);
            const result = try test_stability.run();
            result.print();
            try self.results.append(result);
        }
        
        // Recovery test
        {
            var test_recovery = RecoveryTest.init(self.allocator);
            defer test_recovery.deinit();
            const result = try test_recovery.run(10);
            result.print();
            try self.results.append(result);
        }
    }
    
    pub fn passCount(self: *const StressTestSuite) usize {
        var count: usize = 0;
        for (self.results.items) |r| {
            if (r.passed) count += 1;
        }
        return count;
    }
    
    pub fn summary(self: *const StressTestSuite) void {
        std.debug.print("\n=== Summary ===\n", .{});
        std.debug.print("Total Tests: {}\n", .{self.results.items.len});
        std.debug.print("Passed: {}\n", .{self.passCount()});
        std.debug.print("Failed: {}\n", .{self.results.items.len - self.passCount()});
    }
};

// ==============================================
// Built-in Tests
// ==============================================

test "StressTestConfig presets" {
    const light = StressTestConfig.light();
    try std.testing.expect(light.target_rps == 100);
    
    const heavy = StressTestConfig.heavy();
    try std.testing.expect(heavy.target_rps == 2000);
}

test "FailureInjector" {
    var injector = FailureInjector.init(0.5);
    
    var failures: usize = 0;
    for (0..100) |_| {
        if (injector.injectFailure(.worker_crash)) {
            failures += 1;
        }
    }
    
    // Should have some failures with 50% probability
    try std.testing.expect(failures > 0);
}

test "Stress test suite initialization" {
    const allocator = std.testing.allocator;
    var suite = StressTestSuite.init(allocator);
    defer suite.deinit();
    
    try std.testing.expect(suite.results.items.len == 0);
}
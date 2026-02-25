//! Prometheus Metrics
//!
//! Provides Prometheus-compatible metrics for monitoring.
//! Exposes metrics via HTTP endpoint for scraping.
//!
//! Features:
//! - Counter, Gauge, Histogram, Summary metrics
//! - Labels support
//! - Thread-safe operations
//! - Automatic /metrics endpoint

const std = @import("std");
const log = @import("../utils/logging.zig");

// ==============================================
// Metric Types
// ==============================================

pub const MetricType = enum {
    counter,
    gauge,
    histogram,
    summary,
    
    pub fn toString(self: MetricType) []const u8 {
        return switch (self) {
            .counter => "counter",
            .gauge => "gauge",
            .histogram => "histogram",
            .summary => "summary",
        };
    }
};

// ==============================================
// Counter
// ==============================================

pub const Counter = struct {
    name: []const u8,
    help: []const u8,
    value: std.atomic.Value(u64),
    labels: ?[]const []const u8 = null,
    
    pub fn init(name: []const u8, help: []const u8) Counter {
        return Counter{
            .name = name,
            .help = help,
            .value = std.atomic.Value(u64).init(0),
        };
    }
    
    pub fn inc(self: *Counter) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }
    
    pub fn add(self: *Counter, delta: u64) void {
        _ = self.value.fetchAdd(delta, .monotonic);
    }
    
    pub fn get(self: *Counter) u64 {
        return self.value.load(.monotonic);
    }
    
    pub fn format(self: *Counter, writer: anytype) !void {
        try writer.print("# HELP {s} {s}\n", .{ self.name, self.help });
        try writer.print("# TYPE {s} counter\n", .{self.name});
        try writer.print("{s} {d}\n", .{ self.name, self.get() });
    }
};

// ==============================================
// Gauge
// ==============================================

pub const Gauge = struct {
    name: []const u8,
    help: []const u8,
    value: std.atomic.Value(i64),
    
    pub fn init(name: []const u8, help: []const u8) Gauge {
        return Gauge{
            .name = name,
            .help = help,
            .value = std.atomic.Value(i64).init(0),
        };
    }
    
    pub fn set(self: *Gauge, val: i64) void {
        self.value.store(val, .monotonic);
    }
    
    pub fn inc(self: *Gauge) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }
    
    pub fn dec(self: *Gauge) void {
        _ = self.value.fetchSub(1, .monotonic);
    }
    
    pub fn add(self: *Gauge, delta: i64) void {
        _ = self.value.fetchAdd(delta, .monotonic);
    }
    
    pub fn get(self: *Gauge) i64 {
        return self.value.load(.monotonic);
    }
    
    pub fn format(self: *Gauge, writer: anytype) !void {
        try writer.print("# HELP {s} {s}\n", .{ self.name, self.help });
        try writer.print("# TYPE {s} gauge\n", .{self.name});
        try writer.print("{s} {d}\n", .{ self.name, self.get() });
    }
};

// ==============================================
// Histogram
// ==============================================

pub const Histogram = struct {
    name: []const u8,
    help: []const u8,
    buckets: []const f64,
    counts: []std.atomic.Value(u64),
    sum: std.atomic.Value(u64),  // Store as fixed point (x1000)
    count: std.atomic.Value(u64),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, help: []const u8, buckets: []const f64) !Histogram {
        const counts = try allocator.alloc(std.atomic.Value(u64), buckets.len);
        for (counts) |*c| {
            c.* = std.atomic.Value(u64).init(0);
        }
        
        return Histogram{
            .name = name,
            .help = help,
            .buckets = buckets,
            .counts = counts,
            .sum = std.atomic.Value(u64).init(0),
            .count = std.atomic.Value(u64).init(0),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Histogram) void {
        self.allocator.free(self.counts);
    }
    
    pub fn observe(self: *Histogram, value: f64) void {
        // Update sum (fixed point)
        const fixed_value = @as(u64, @intFromFloat(value * 1000));
        _ = self.sum.fetchAdd(fixed_value, .monotonic);
        _ = self.count.fetchAdd(1, .monotonic);
        
        // Update bucket counts
        for (self.buckets, 0..) |bucket, i| {
            if (value <= bucket) {
                _ = self.counts[i].fetchAdd(1, .monotonic);
            }
        }
    }
    
    pub fn format(self: *Histogram, writer: anytype) !void {
        try writer.print("# HELP {s} {s}\n", .{ self.name, self.help });
        try writer.print("# TYPE {s} histogram\n", .{self.name});
        
        var cumulative: u64 = 0;
        for (self.buckets, 0..) |bucket, i| {
            cumulative += self.counts[i].load(.monotonic);
            try writer.print("{s}_bucket{{le=\"{d:.3}\"}} {d}\n", .{
                self.name, bucket, cumulative,
            });
        }
        
        // +Inf bucket
        try writer.print("{s}_bucket{{le=\"+Inf\"}} {d}\n", .{
            self.name, self.count.load(.monotonic),
        });
        
        // Sum and count
        const sum_val = @as(f64, @floatFromInt(self.sum.load(.monotonic))) / 1000.0;
        try writer.print("{s}_sum {d:.3}\n", .{ self.name, sum_val });
        try writer.print("{s}_count {d}\n", .{ self.name, self.count.load(.monotonic) });
    }
};

// ==============================================
// Default Buckets
// ==============================================

pub const DEFAULT_LATENCY_BUCKETS = [_]f64{
    0.001, 0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0,
};

pub const DEFAULT_TOKEN_BUCKETS = [_]f64{
    1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000,
};

// ==============================================
// Metrics Registry
// ==============================================

pub const MetricsRegistry = struct {
    allocator: std.mem.Allocator,
    counters: std.StringHashMap(*Counter),
    gauges: std.StringHashMap(*Gauge),
    histograms: std.StringHashMap(*Histogram),
    mutex: std.Thread.Mutex = .{},
    
    pub fn init(allocator: std.mem.Allocator) MetricsRegistry {
        return MetricsRegistry{
            .allocator = allocator,
            .counters = std.StringHashMap(*Counter).init(allocator),
            .gauges = std.StringHashMap(*Gauge).init(allocator),
            .histograms = std.StringHashMap(*Histogram).init(allocator),
        };
    }
    
    pub fn deinit(self: *MetricsRegistry) void {
        // Free counters
        var counter_it = self.counters.valueIterator();
        while (counter_it.next()) |c| {
            self.allocator.destroy(c.*);
        }
        self.counters.deinit();
        
        // Free gauges
        var gauge_it = self.gauges.valueIterator();
        while (gauge_it.next()) |g| {
            self.allocator.destroy(g.*);
        }
        self.gauges.deinit();
        
        // Free histograms
        var hist_it = self.histograms.valueIterator();
        while (hist_it.next()) |h| {
            h.*.deinit();
            self.allocator.destroy(h.*);
        }
        self.histograms.deinit();
    }
    
    pub fn registerCounter(self: *MetricsRegistry, name: []const u8, help: []const u8) !*Counter {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.counters.get(name)) |existing| {
            return existing;
        }
        
        const counter = try self.allocator.create(Counter);
        counter.* = Counter.init(name, help);
        try self.counters.put(name, counter);
        return counter;
    }
    
    pub fn registerGauge(self: *MetricsRegistry, name: []const u8, help: []const u8) !*Gauge {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.gauges.get(name)) |existing| {
            return existing;
        }
        
        const gauge = try self.allocator.create(Gauge);
        gauge.* = Gauge.init(name, help);
        try self.gauges.put(name, gauge);
        return gauge;
    }
    
    pub fn registerHistogram(
        self: *MetricsRegistry,
        name: []const u8,
        help: []const u8,
        buckets: []const f64,
    ) !*Histogram {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.histograms.get(name)) |existing| {
            return existing;
        }
        
        const histogram = try self.allocator.create(Histogram);
        histogram.* = try Histogram.init(self.allocator, name, help, buckets);
        try self.histograms.put(name, histogram);
        return histogram;
    }
    
    pub fn format(self: *MetricsRegistry, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var buffer = std.ArrayList(u8).init(allocator);
        const writer = buffer.writer();
        
        // Format counters
        var counter_it = self.counters.valueIterator();
        while (counter_it.next()) |c| {
            try c.*.format(writer);
            try writer.writeByte('\n');
        }
        
        // Format gauges
        var gauge_it = self.gauges.valueIterator();
        while (gauge_it.next()) |g| {
            try g.*.format(writer);
            try writer.writeByte('\n');
        }
        
        // Format histograms
        var hist_it = self.histograms.valueIterator();
        while (hist_it.next()) |h| {
            try h.*.format(writer);
            try writer.writeByte('\n');
        }
        
        return buffer.toOwnedSlice();
    }
};

// ==============================================
// vLLM Metrics
// ==============================================

pub const VllmMetrics = struct {
    registry: MetricsRegistry,
    
    // Request metrics
    requests_total: *Counter,
    requests_success: *Counter,
    requests_failed: *Counter,
    
    // Latency metrics
    request_latency: *Histogram,
    time_to_first_token: *Histogram,
    inter_token_latency: *Histogram,
    
    // Token metrics
    prompt_tokens_total: *Counter,
    completion_tokens_total: *Counter,
    tokens_per_request: *Histogram,
    
    // Resource metrics
    gpu_memory_used: *Gauge,
    gpu_utilization: *Gauge,
    kv_cache_usage: *Gauge,
    active_requests: *Gauge,
    pending_requests: *Gauge,
    
    // Model metrics
    model_load_time: *Gauge,
    
    pub fn init(allocator: std.mem.Allocator) !VllmMetrics {
        var registry = MetricsRegistry.init(allocator);
        
        return VllmMetrics{
            .registry = registry,
            
            // Request metrics
            .requests_total = try registry.registerCounter(
                "vllm_requests_total",
                "Total number of requests",
            ),
            .requests_success = try registry.registerCounter(
                "vllm_requests_success_total",
                "Total successful requests",
            ),
            .requests_failed = try registry.registerCounter(
                "vllm_requests_failed_total",
                "Total failed requests",
            ),
            
            // Latency metrics
            .request_latency = try registry.registerHistogram(
                "vllm_request_latency_seconds",
                "Request latency in seconds",
                &DEFAULT_LATENCY_BUCKETS,
            ),
            .time_to_first_token = try registry.registerHistogram(
                "vllm_time_to_first_token_seconds",
                "Time to first token in seconds",
                &DEFAULT_LATENCY_BUCKETS,
            ),
            .inter_token_latency = try registry.registerHistogram(
                "vllm_inter_token_latency_seconds",
                "Inter-token latency in seconds",
                &[_]f64{ 0.001, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5 },
            ),
            
            // Token metrics
            .prompt_tokens_total = try registry.registerCounter(
                "vllm_prompt_tokens_total",
                "Total prompt tokens processed",
            ),
            .completion_tokens_total = try registry.registerCounter(
                "vllm_completion_tokens_total",
                "Total completion tokens generated",
            ),
            .tokens_per_request = try registry.registerHistogram(
                "vllm_tokens_per_request",
                "Tokens per request",
                &DEFAULT_TOKEN_BUCKETS,
            ),
            
            // Resource metrics
            .gpu_memory_used = try registry.registerGauge(
                "vllm_gpu_memory_used_bytes",
                "GPU memory used in bytes",
            ),
            .gpu_utilization = try registry.registerGauge(
                "vllm_gpu_utilization_percent",
                "GPU utilization percentage",
            ),
            .kv_cache_usage = try registry.registerGauge(
                "vllm_kv_cache_usage_percent",
                "KV cache usage percentage",
            ),
            .active_requests = try registry.registerGauge(
                "vllm_active_requests",
                "Currently active requests",
            ),
            .pending_requests = try registry.registerGauge(
                "vllm_pending_requests",
                "Pending requests in queue",
            ),
            
            // Model metrics
            .model_load_time = try registry.registerGauge(
                "vllm_model_load_time_seconds",
                "Model load time in seconds",
            ),
        };
    }
    
    pub fn deinit(self: *VllmMetrics) void {
        self.registry.deinit();
    }
    
    /// Record a completed request
    pub fn recordRequest(
        self: *VllmMetrics,
        success: bool,
        latency_seconds: f64,
        prompt_tokens: u64,
        completion_tokens: u64,
    ) void {
        self.requests_total.inc();
        
        if (success) {
            self.requests_success.inc();
        } else {
            self.requests_failed.inc();
        }
        
        self.request_latency.observe(latency_seconds);
        self.prompt_tokens_total.add(prompt_tokens);
        self.completion_tokens_total.add(completion_tokens);
        self.tokens_per_request.observe(@as(f64, @floatFromInt(prompt_tokens + completion_tokens)));
    }
    
    /// Update resource metrics
    pub fn updateResources(
        self: *VllmMetrics,
        gpu_memory_bytes: i64,
        gpu_util_percent: i64,
        kv_cache_percent: i64,
        active: i64,
        pending: i64,
    ) void {
        self.gpu_memory_used.set(gpu_memory_bytes);
        self.gpu_utilization.set(gpu_util_percent);
        self.kv_cache_usage.set(kv_cache_percent);
        self.active_requests.set(active);
        self.pending_requests.set(pending);
    }
    
    /// Get Prometheus format output
    pub fn format(self: *VllmMetrics, allocator: std.mem.Allocator) ![]u8 {
        return self.registry.format(allocator);
    }
};

// ==============================================
// Tests
// ==============================================

test "Counter operations" {
    var counter = Counter.init("test_counter", "Test counter");
    
    try std.testing.expectEqual(@as(u64, 0), counter.get());
    
    counter.inc();
    try std.testing.expectEqual(@as(u64, 1), counter.get());
    
    counter.add(5);
    try std.testing.expectEqual(@as(u64, 6), counter.get());
}

test "Gauge operations" {
    var gauge = Gauge.init("test_gauge", "Test gauge");
    
    gauge.set(100);
    try std.testing.expectEqual(@as(i64, 100), gauge.get());
    
    gauge.inc();
    try std.testing.expectEqual(@as(i64, 101), gauge.get());
    
    gauge.dec();
    try std.testing.expectEqual(@as(i64, 100), gauge.get());
}

test "Histogram observe" {
    const allocator = std.testing.allocator;
    var histogram = try Histogram.init(
        allocator,
        "test_histogram",
        "Test histogram",
        &[_]f64{ 0.1, 0.5, 1.0 },
    );
    defer histogram.deinit();
    
    histogram.observe(0.05);  // Goes in 0.1 bucket
    histogram.observe(0.3);   // Goes in 0.5 bucket
    histogram.observe(0.8);   // Goes in 1.0 bucket
    
    try std.testing.expectEqual(@as(u64, 3), histogram.count.load(.monotonic));
}
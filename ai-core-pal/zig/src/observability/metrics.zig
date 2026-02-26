//! ANWID Prometheus Metrics
//! Exports request rates, batch sizes, GPU utilization, and queue depths
//! Format: Prometheus text exposition format

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.metrics);

// ============================================================================
// Metric Types
// ============================================================================

pub const Counter = struct {
    name: []const u8,
    help: []const u8,
    labels: ?[]const u8,
    value: std.atomic.Value(u64),
    
    pub fn init(name: []const u8, help: []const u8, labels: ?[]const u8) Counter {
        return .{
            .name = name,
            .help = help,
            .labels = labels,
            .value = std.atomic.Value(u64).init(0),
        };
    }
    
    pub fn inc(self: *Counter) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }
    
    pub fn add(self: *Counter, n: u64) void {
        _ = self.value.fetchAdd(n, .monotonic);
    }
    
    pub fn get(self: *const Counter) u64 {
        return self.value.load(.acquire);
    }
};

pub const Gauge = struct {
    name: []const u8,
    help: []const u8,
    labels: ?[]const u8,
    value: std.atomic.Value(i64),
    
    pub fn init(name: []const u8, help: []const u8, labels: ?[]const u8) Gauge {
        return .{
            .name = name,
            .help = help,
            .labels = labels,
            .value = std.atomic.Value(i64).init(0),
        };
    }
    
    pub fn set(self: *Gauge, v: i64) void {
        self.value.store(v, .release);
    }
    
    pub fn inc(self: *Gauge) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }
    
    pub fn dec(self: *Gauge) void {
        _ = self.value.fetchSub(1, .monotonic);
    }
    
    pub fn get(self: *const Gauge) i64 {
        return self.value.load(.acquire);
    }
};

pub const Histogram = struct {
    name: []const u8,
    help: []const u8,
    buckets: []const f64,
    counts: []std.atomic.Value(u64),
    sum: std.atomic.Value(u64),
    count: std.atomic.Value(u64),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, help: []const u8, buckets: []const f64) !*Histogram {
        const h = try allocator.create(Histogram);
        const counts = try allocator.alloc(std.atomic.Value(u64), buckets.len + 1);
        for (counts) |*c| c.* = std.atomic.Value(u64).init(0);
        
        h.* = .{
            .name = name,
            .help = help,
            .buckets = buckets,
            .counts = counts,
            .sum = std.atomic.Value(u64).init(0),
            .count = std.atomic.Value(u64).init(0),
            .allocator = allocator,
        };
        return h;
    }
    
    pub fn deinit(self: *Histogram) void {
        self.allocator.free(self.counts);
        self.allocator.destroy(self);
    }
    
    pub fn observe(self: *Histogram, value: f64) void {
        // Find bucket
        for (self.buckets, 0..) |bound, i| {
            if (value <= bound) {
                _ = self.counts[i].fetchAdd(1, .monotonic);
                break;
            }
        }
        // +Inf bucket
        _ = self.counts[self.buckets.len].fetchAdd(1, .monotonic);
        
        // Update sum and count
        _ = self.sum.fetchAdd(@intFromFloat(value), .monotonic);
        _ = self.count.fetchAdd(1, .monotonic);
    }
};

// ============================================================================
// ANWID Metrics Registry
// ============================================================================

pub const AnwidMetrics = struct {
    // Request metrics
    requests_total: Counter,
    requests_in_flight: Gauge,
    request_duration_seconds: ?*Histogram,
    
    // Batch metrics
    batches_processed_total: Counter,
    batch_size_current: Gauge,
    batch_queue_depth: Gauge,
    
    // GPU metrics
    gpu_utilization_percent: Gauge,
    gpu_memory_used_bytes: Gauge,
    gpu_kernel_dispatches_total: Counter,
    
    // NIM metrics
    nim_requests_total: Counter,
    nim_errors_total: Counter,
    nim_latency_seconds: ?*Histogram,
    nim_circuit_open: Gauge,
    
    // Pipeline metrics
    pipeline_slots_active: Gauge,
    pipeline_throughput_rps: Gauge,
    
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) !*AnwidMetrics {
        const m = try allocator.create(AnwidMetrics);
        
        // Default latency buckets (in seconds)
        const latency_buckets = &[_]f64{ 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0 };
        
        m.* = .{
            .requests_total = Counter.init("anwid_requests_total", "Total number of requests processed", null),
            .requests_in_flight = Gauge.init("anwid_requests_in_flight", "Number of requests currently being processed", null),
            .request_duration_seconds = try Histogram.init(allocator, "anwid_request_duration_seconds", "Request duration in seconds", latency_buckets),
            
            .batches_processed_total = Counter.init("anwid_batches_processed_total", "Total number of batches processed", null),
            .batch_size_current = Gauge.init("anwid_batch_size_current", "Current batch size", null),
            .batch_queue_depth = Gauge.init("anwid_batch_queue_depth", "Number of requests waiting in batch queue", null),
            
            .gpu_utilization_percent = Gauge.init("anwid_gpu_utilization_percent", "GPU utilization percentage", null),
            .gpu_memory_used_bytes = Gauge.init("anwid_gpu_memory_used_bytes", "GPU memory usage in bytes", null),
            .gpu_kernel_dispatches_total = Counter.init("anwid_gpu_kernel_dispatches_total", "Total GPU kernel dispatches", null),
            
            .nim_requests_total = Counter.init("anwid_nim_requests_total", "Total NIM API requests", null),
            .nim_errors_total = Counter.init("anwid_nim_errors_total", "Total NIM API errors", null),
            .nim_latency_seconds = try Histogram.init(allocator, "anwid_nim_latency_seconds", "NIM API latency in seconds", latency_buckets),
            .nim_circuit_open = Gauge.init("anwid_nim_circuit_open", "NIM circuit breaker state (1=open, 0=closed)", null),
            
            .pipeline_slots_active = Gauge.init("anwid_pipeline_slots_active", "Number of active pipeline slots", null),
            .pipeline_throughput_rps = Gauge.init("anwid_pipeline_throughput_rps", "Pipeline throughput in requests/second", null),
            
            .allocator = allocator,
        };
        
        log.info("Metrics registry initialized", .{});
        return m;
    }
    
    pub fn deinit(self: *AnwidMetrics) void {
        if (self.request_duration_seconds) |h| h.deinit();
        if (self.nim_latency_seconds) |h| h.deinit();
        self.allocator.destroy(self);
        log.info("Metrics registry destroyed", .{});
    }
    
    /// Serialize all metrics to Prometheus text format
    pub fn serialize(self: *const AnwidMetrics, allocator: std.mem.Allocator) ![]u8 {
        var list = std.ArrayList(u8).init(allocator);
        const writer = list.writer();
        
        // Request metrics
        try self.writeCounter(writer, &self.requests_total);
        try self.writeGauge(writer, &self.requests_in_flight);
        
        // Batch metrics
        try self.writeCounter(writer, &self.batches_processed_total);
        try self.writeGauge(writer, &self.batch_size_current);
        try self.writeGauge(writer, &self.batch_queue_depth);
        
        // GPU metrics
        try self.writeGauge(writer, &self.gpu_utilization_percent);
        try self.writeGauge(writer, &self.gpu_memory_used_bytes);
        try self.writeCounter(writer, &self.gpu_kernel_dispatches_total);
        
        // NIM metrics
        try self.writeCounter(writer, &self.nim_requests_total);
        try self.writeCounter(writer, &self.nim_errors_total);
        try self.writeGauge(writer, &self.nim_circuit_open);
        
        // Pipeline metrics
        try self.writeGauge(writer, &self.pipeline_slots_active);
        try self.writeGauge(writer, &self.pipeline_throughput_rps);
        
        return list.toOwnedSlice();
    }
    
    fn writeCounter(self: *const AnwidMetrics, writer: anytype, counter: *const Counter) !void {
        _ = self;
        try writer.print("# HELP {s} {s}\n", .{ counter.name, counter.help });
        try writer.print("# TYPE {s} counter\n", .{counter.name});
        if (counter.labels) |labels| {
            try writer.print("{s}{{{s}}} {}\n", .{ counter.name, labels, counter.get() });
        } else {
            try writer.print("{s} {}\n", .{ counter.name, counter.get() });
        }
    }
    
    fn writeGauge(self: *const AnwidMetrics, writer: anytype, gauge: *const Gauge) !void {
        _ = self;
        try writer.print("# HELP {s} {s}\n", .{ gauge.name, gauge.help });
        try writer.print("# TYPE {s} gauge\n", .{gauge.name});
        if (gauge.labels) |labels| {
            try writer.print("{s}{{{s}}} {}\n", .{ gauge.name, labels, gauge.get() });
        } else {
            try writer.print("{s} {}\n", .{ gauge.name, gauge.get() });
        }
    }
};

// ============================================================================
// Global Metrics Instance
// ============================================================================

var global_metrics: ?*AnwidMetrics = null;

pub fn initGlobal(allocator: std.mem.Allocator) !void {
    global_metrics = try AnwidMetrics.init(allocator);
}

pub fn deinitGlobal() void {
    if (global_metrics) |m| m.deinit();
    global_metrics = null;
}

pub fn getGlobal() ?*AnwidMetrics {
    return global_metrics;
}

// ============================================================================
// Tests
// ============================================================================

test "Counter operations" {
    var c = Counter.init("test_counter", "A test counter", null);
    
    try std.testing.expectEqual(@as(u64, 0), c.get());
    c.inc();
    try std.testing.expectEqual(@as(u64, 1), c.get());
    c.add(5);
    try std.testing.expectEqual(@as(u64, 6), c.get());
}

test "Gauge operations" {
    var g = Gauge.init("test_gauge", "A test gauge", null);
    
    try std.testing.expectEqual(@as(i64, 0), g.get());
    g.set(100);
    try std.testing.expectEqual(@as(i64, 100), g.get());
    g.inc();
    try std.testing.expectEqual(@as(i64, 101), g.get());
    g.dec();
    try std.testing.expectEqual(@as(i64, 100), g.get());
}

test "Metrics serialization" {
    const metrics = try AnwidMetrics.init(std.testing.allocator);
    defer metrics.deinit();
    
    metrics.requests_total.add(100);
    metrics.gpu_utilization_percent.set(85);
    
    const output = try metrics.serialize(std.testing.allocator);
    defer std.testing.allocator.free(output);
    
    try std.testing.expect(std.mem.indexOf(u8, output, "anwid_requests_total 100") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "anwid_gpu_utilization_percent 85") != null);
}
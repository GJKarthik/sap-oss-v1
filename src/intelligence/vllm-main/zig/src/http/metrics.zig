//! PrivateLLM Prometheus Metrics
//! Thread-safe metrics in Prometheus text exposition format for /metrics endpoint.
//! All counters/gauges use std.atomic.Value for lock-free concurrent access.

const std = @import("std");

// ============================================================================
// Histogram Bucket Boundaries (seconds)
// ============================================================================

/// Latency histogram bucket upper bounds in milliseconds.
/// Prometheus convention: expose as seconds in output.
const bucket_bounds_ms = [_]u64{ 5, 10, 25, 50, 100, 250, 500, 1000, 5000 };
const bucket_count = bucket_bounds_ms.len;

// ============================================================================
// Metrics
// ============================================================================

pub const Metrics = struct {
    // Counters
    requests_total: std.atomic.Value(u64),
    requests_failed: std.atomic.Value(u64),
    tokens_generated: std.atomic.Value(u64),
    engram_predictions: std.atomic.Value(u64),
    engram_overrides: std.atomic.Value(u64),
    engram_promotions: std.atomic.Value(u64),
    engram_demotions: std.atomic.Value(u64),
    engram_confidence_sum_milli: std.atomic.Value(u64),
    engram_confidence_count: std.atomic.Value(u64),
    engram_last_confidence_milli: std.atomic.Value(u64),

    // Histogram: request duration
    request_duration_sum_ns: std.atomic.Value(u64),
    request_count: std.atomic.Value(u64),
    latency_buckets: [bucket_count]std.atomic.Value(u64),

    // Gauges
    active_connections: std.atomic.Value(u64),
    circuit_breaker_state: std.atomic.Value(u32),
    gpu_memory_used: std.atomic.Value(u64),
    gpu_memory_total: std.atomic.Value(u64),

    /// Initialize all metrics to zero.
    pub fn init() Metrics {
        var m = Metrics{
            .requests_total = std.atomic.Value(u64).init(0),
            .requests_failed = std.atomic.Value(u64).init(0),
            .tokens_generated = std.atomic.Value(u64).init(0),
            .engram_predictions = std.atomic.Value(u64).init(0),
            .engram_overrides = std.atomic.Value(u64).init(0),
            .engram_promotions = std.atomic.Value(u64).init(0),
            .engram_demotions = std.atomic.Value(u64).init(0),
            .engram_confidence_sum_milli = std.atomic.Value(u64).init(0),
            .engram_confidence_count = std.atomic.Value(u64).init(0),
            .engram_last_confidence_milli = std.atomic.Value(u64).init(0),
            .request_duration_sum_ns = std.atomic.Value(u64).init(0),
            .request_count = std.atomic.Value(u64).init(0),
            .latency_buckets = undefined,
            .active_connections = std.atomic.Value(u64).init(0),
            .circuit_breaker_state = std.atomic.Value(u32).init(0),
            .gpu_memory_used = std.atomic.Value(u64).init(0),
            .gpu_memory_total = std.atomic.Value(u64).init(0),
        };
        for (&m.latency_buckets) |*b| {
            b.* = std.atomic.Value(u64).init(0);
        }
        return m;
    }

    // ========================================================================
    // Recording helpers
    // ========================================================================

    /// Record a completed request. Updates counters, histogram buckets, and duration sum.
    pub fn recordRequest(self: *Metrics, duration_ns: u64, success: bool) void {
        _ = self.requests_total.fetchAdd(1, .monotonic);
        _ = self.request_count.fetchAdd(1, .monotonic);
        _ = self.request_duration_sum_ns.fetchAdd(duration_ns, .monotonic);

        if (!success) {
            _ = self.requests_failed.fetchAdd(1, .monotonic);
        }

        // Increment all buckets whose bound >= observed value (cumulative)
        const duration_ms = duration_ns / std.time.ns_per_ms;
        for (&self.latency_buckets, 0..) |*bucket, i| {
            if (duration_ms <= bucket_bounds_ms[i]) {
                _ = bucket.fetchAdd(1, .monotonic);
            }
        }
    }

    pub fn addTokens(self: *Metrics, count: u64) void {
        _ = self.tokens_generated.fetchAdd(count, .monotonic);
    }

    pub fn recordEngramPrediction(self: *Metrics, confidence: f32, overridden: bool, promoted: bool, demoted: bool) void {
        const clamped = @max(0.0, @min(confidence, 1.0));
        const milli = @as(u64, @intFromFloat(clamped * 1000.0));
        _ = self.engram_predictions.fetchAdd(1, .monotonic);
        _ = self.engram_confidence_sum_milli.fetchAdd(milli, .monotonic);
        _ = self.engram_confidence_count.fetchAdd(1, .monotonic);
        self.engram_last_confidence_milli.store(milli, .monotonic);
        if (overridden) _ = self.engram_overrides.fetchAdd(1, .monotonic);
        if (promoted) _ = self.engram_promotions.fetchAdd(1, .monotonic);
        if (demoted) _ = self.engram_demotions.fetchAdd(1, .monotonic);
    }

    pub fn connectionOpened(self: *Metrics) void {
        _ = self.active_connections.fetchAdd(1, .monotonic);
    }

    pub fn connectionClosed(self: *Metrics) void {
        _ = self.active_connections.fetchSub(1, .monotonic);
    }

    pub fn setCircuitBreakerState(self: *Metrics, state: u32) void {
        self.circuit_breaker_state.store(state, .monotonic);
    }

    pub fn setGpuMemory(self: *Metrics, used: u64, total: u64) void {
        self.gpu_memory_used.store(used, .monotonic);
        self.gpu_memory_total.store(total, .monotonic);
    }

    // ========================================================================
    // Prometheus text format
    // ========================================================================

    /// Write all metrics in Prometheus text exposition format.
    pub fn format(self: *const Metrics, writer: anytype) !void {
        // -- requests_total (counter) --
        try writer.writeAll("# HELP privatellm_requests_total Total HTTP requests\n");
        try writer.writeAll("# TYPE privatellm_requests_total counter\n");
        try std.fmt.format(writer, "privatellm_requests_total {d}\n", .{self.requests_total.load(.monotonic)});
        try std.fmt.format(writer, "privatellm_requests_failed_total {d}\n", .{self.requests_failed.load(.monotonic)});

        // -- request_duration_seconds (histogram) --
        try writer.writeAll("# HELP privatellm_request_duration_seconds Request latency\n");
        try writer.writeAll("# TYPE privatellm_request_duration_seconds histogram\n");

        const count = self.request_count.load(.monotonic);
        var cumulative: u64 = 0;
        for (&self.latency_buckets, 0..) |*bucket, i| {
            cumulative += bucket.load(.monotonic);
            const bound_ms = bucket_bounds_ms[i];
            // Convert ms to seconds for the le label
            const secs = @as(f64, @floatFromInt(bound_ms)) / 1000.0;
            try std.fmt.format(writer, "privatellm_request_duration_seconds_bucket{{le=\"{d:.3}\"}} {d}\n", .{ secs, cumulative });
        }
        try std.fmt.format(writer, "privatellm_request_duration_seconds_bucket{{le=\"+Inf\"}} {d}\n", .{count});

        const sum_ns = self.request_duration_sum_ns.load(.monotonic);
        const sum_secs = @as(f64, @floatFromInt(sum_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        try std.fmt.format(writer, "privatellm_request_duration_seconds_sum {d:.6}\n", .{sum_secs});
        try std.fmt.format(writer, "privatellm_request_duration_seconds_count {d}\n", .{count});

        // -- tokens_generated_total (counter) --
        try writer.writeAll("# HELP privatellm_tokens_generated_total Total tokens generated\n");
        try writer.writeAll("# TYPE privatellm_tokens_generated_total counter\n");
        try std.fmt.format(writer, "privatellm_tokens_generated_total {d}\n", .{self.tokens_generated.load(.monotonic)});

        // -- engram ensemble counters/gauges --
        try writer.writeAll("# HELP privatellm_engram_predictions_total Total Engram ensemble predictions\n");
        try writer.writeAll("# TYPE privatellm_engram_predictions_total counter\n");
        try std.fmt.format(writer, "privatellm_engram_predictions_total {d}\n", .{self.engram_predictions.load(.monotonic)});
        try std.fmt.format(writer, "privatellm_engram_overrides_total {d}\n", .{self.engram_overrides.load(.monotonic)});
        try std.fmt.format(writer, "privatellm_engram_promotions_total {d}\n", .{self.engram_promotions.load(.monotonic)});
        try std.fmt.format(writer, "privatellm_engram_demotions_total {d}\n", .{self.engram_demotions.load(.monotonic)});

        const conf_count = self.engram_confidence_count.load(.monotonic);
        const conf_sum_milli = self.engram_confidence_sum_milli.load(.monotonic);
        const conf_avg = if (conf_count > 0)
            @as(f64, @floatFromInt(conf_sum_milli)) / (@as(f64, @floatFromInt(conf_count)) * 1000.0)
        else
            0.0;
        const conf_last = @as(f64, @floatFromInt(self.engram_last_confidence_milli.load(.monotonic))) / 1000.0;
        try writer.writeAll("# HELP privatellm_engram_confidence_avg Average Engram confidence [0,1]\n");
        try writer.writeAll("# TYPE privatellm_engram_confidence_avg gauge\n");
        try std.fmt.format(writer, "privatellm_engram_confidence_avg {d:.3}\n", .{conf_avg});
        try writer.writeAll("# HELP privatellm_engram_confidence_last Last Engram confidence [0,1]\n");
        try writer.writeAll("# TYPE privatellm_engram_confidence_last gauge\n");
        try std.fmt.format(writer, "privatellm_engram_confidence_last {d:.3}\n", .{conf_last});

        // -- active_connections (gauge) --
        try writer.writeAll("# HELP privatellm_active_connections Current active connections\n");
        try writer.writeAll("# TYPE privatellm_active_connections gauge\n");
        try std.fmt.format(writer, "privatellm_active_connections {d}\n", .{self.active_connections.load(.monotonic)});

        // -- circuit_breaker_state (gauge: 0=closed, 1=open, 2=half-open) --
        try writer.writeAll("# HELP privatellm_circuit_breaker_state Circuit breaker state (0=closed, 1=open, 2=half-open)\n");
        try writer.writeAll("# TYPE privatellm_circuit_breaker_state gauge\n");
        try std.fmt.format(writer, "privatellm_circuit_breaker_state {d}\n", .{self.circuit_breaker_state.load(.monotonic)});

        // -- gpu_memory_used_bytes (gauge) --
        try writer.writeAll("# HELP privatellm_gpu_memory_used_bytes GPU memory currently used\n");
        try writer.writeAll("# TYPE privatellm_gpu_memory_used_bytes gauge\n");
        try std.fmt.format(writer, "privatellm_gpu_memory_used_bytes {d}\n", .{self.gpu_memory_used.load(.monotonic)});

        // -- gpu_memory_total_bytes (gauge) --
        try writer.writeAll("# HELP privatellm_gpu_memory_total_bytes GPU memory total capacity\n");
        try writer.writeAll("# TYPE privatellm_gpu_memory_total_bytes gauge\n");
        try std.fmt.format(writer, "privatellm_gpu_memory_total_bytes {d}\n", .{self.gpu_memory_total.load(.monotonic)});
    }
};

// ============================================================================
// Global singleton (one per process, no allocator needed)
// ============================================================================

var global: Metrics = Metrics.init();

pub fn getGlobal() *Metrics {
    return &global;
}

// ============================================================================
// Tests
// ============================================================================

test "init zeros all fields" {
    const m = Metrics.init();
    try std.testing.expectEqual(@as(u64, 0), m.requests_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), m.requests_failed.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), m.tokens_generated.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), m.engram_predictions.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), m.engram_overrides.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), m.engram_promotions.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), m.engram_demotions.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), m.request_count.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), m.request_duration_sum_ns.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), m.active_connections.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), m.circuit_breaker_state.load(.monotonic));
    for (&m.latency_buckets) |*b| {
        try std.testing.expectEqual(@as(u64, 0), b.load(.monotonic));
    }
}

test "recordRequest updates counters and histogram" {
    var m = Metrics.init();

    // 8ms successful request
    m.recordRequest(8 * std.time.ns_per_ms, true);
    try std.testing.expectEqual(@as(u64, 1), m.requests_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), m.requests_failed.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), m.request_count.load(.monotonic));
    try std.testing.expectEqual(8 * std.time.ns_per_ms, m.request_duration_sum_ns.load(.monotonic));

    // 8ms falls into buckets with bounds >= 8: 10, 25, 50, 100, 250, 500, 1000, 5000
    // bucket index 0 (5ms) should be 0, index 1 (10ms) should be 1
    try std.testing.expectEqual(@as(u64, 0), m.latency_buckets[0].load(.monotonic)); // 5ms
    try std.testing.expectEqual(@as(u64, 1), m.latency_buckets[1].load(.monotonic)); // 10ms
    try std.testing.expectEqual(@as(u64, 1), m.latency_buckets[2].load(.monotonic)); // 25ms

    // 3ms failed request
    m.recordRequest(3 * std.time.ns_per_ms, false);
    try std.testing.expectEqual(@as(u64, 2), m.requests_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), m.requests_failed.load(.monotonic));
    // 3ms fits in 5ms bucket
    try std.testing.expectEqual(@as(u64, 1), m.latency_buckets[0].load(.monotonic)); // 5ms
    try std.testing.expectEqual(@as(u64, 2), m.latency_buckets[1].load(.monotonic)); // 10ms
}

test "format produces valid Prometheus text" {
    var m = Metrics.init();
    m.recordRequest(50 * std.time.ns_per_ms, true);
    m.recordRequest(200 * std.time.ns_per_ms, false);
    m.addTokens(42);
    m.recordEngramPrediction(0.91, true, true, false);
    m.recordEngramPrediction(0.20, false, false, false);
    m.connectionOpened();
    m.setCircuitBreakerState(1);
    m.setGpuMemory(1024 * 1024 * 512, 1024 * 1024 * 1024);

    var buf: [8192]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try m.format(stream.writer());
    const output = stream.getWritten();

    // Verify key metric lines are present
    try std.testing.expect(std.mem.indexOf(u8, output, "privatellm_requests_total 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "privatellm_requests_failed_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "privatellm_tokens_generated_total 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "privatellm_engram_predictions_total 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "privatellm_engram_overrides_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "privatellm_engram_promotions_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "privatellm_active_connections 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "privatellm_circuit_breaker_state 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "privatellm_gpu_memory_used_bytes 536870912") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "privatellm_gpu_memory_total_bytes 1073741824") != null);
    // Histogram structure
    try std.testing.expect(std.mem.indexOf(u8, output, "# TYPE privatellm_request_duration_seconds histogram") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "privatellm_request_duration_seconds_bucket{le=\"+Inf\"} 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "privatellm_request_duration_seconds_count 2") != null);
}

test "gauge helpers" {
    var m = Metrics.init();

    m.connectionOpened();
    m.connectionOpened();
    try std.testing.expectEqual(@as(u64, 2), m.active_connections.load(.monotonic));
    m.connectionClosed();
    try std.testing.expectEqual(@as(u64, 1), m.active_connections.load(.monotonic));

    m.setCircuitBreakerState(2); // half-open
    try std.testing.expectEqual(@as(u32, 2), m.circuit_breaker_state.load(.monotonic));

    m.setGpuMemory(100, 200);
    try std.testing.expectEqual(@as(u64, 100), m.gpu_memory_used.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 200), m.gpu_memory_total.load(.monotonic));
}

test "recordEngramPrediction updates counters" {
    var m = Metrics.init();
    m.recordEngramPrediction(0.87, true, true, false);
    m.recordEngramPrediction(0.10, true, false, true);

    try std.testing.expectEqual(@as(u64, 2), m.engram_predictions.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 2), m.engram_overrides.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), m.engram_promotions.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), m.engram_demotions.load(.monotonic));
    try std.testing.expect(m.engram_last_confidence_milli.load(.monotonic) <= 1000);
}

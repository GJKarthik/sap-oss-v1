//! BDC AIPrompt Streaming - Prometheus Metrics
//! Atomic counters and histograms; serialises to Prometheus text exposition format.
//! The broker's /metrics HTTP endpoint calls renderText() to serve scrapers.

const std = @import("std");

/// Latency histogram bucket boundaries in microseconds.
const LAT_BUCKETS_US = [_]u64{ 100, 500, 1_000, 5_000, 10_000, 50_000, 100_000, 500_000 };
const N_BUCKETS = LAT_BUCKETS_US.len + 1; // +1 for the +Inf bucket

pub const PrometheusMetrics = struct {
    allocator: std.mem.Allocator,

    // Counters (atomics so they are safe from multiple handler threads)
    messages_in:   std.atomic.Value(u64),
    messages_out:  std.atomic.Value(u64),
    bytes_in:      std.atomic.Value(u64),
    bytes_out:     std.atomic.Value(u64),
    connections:   std.atomic.Value(u64),
    errors_total:  std.atomic.Value(u64),

    // Latency histogram (end-to-end publish, in microseconds)
    lat_buckets:   [N_BUCKETS]std.atomic.Value(u64),
    lat_sum_us:    std.atomic.Value(u64),
    lat_count:     std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator) PrometheusMetrics {
        var m = PrometheusMetrics{
            .allocator    = allocator,
            .messages_in  = std.atomic.Value(u64).init(0),
            .messages_out = std.atomic.Value(u64).init(0),
            .bytes_in     = std.atomic.Value(u64).init(0),
            .bytes_out    = std.atomic.Value(u64).init(0),
            .connections  = std.atomic.Value(u64).init(0),
            .errors_total = std.atomic.Value(u64).init(0),
            .lat_buckets  = undefined,
            .lat_sum_us   = std.atomic.Value(u64).init(0),
            .lat_count    = std.atomic.Value(u64).init(0),
        };
        for (&m.lat_buckets) |*b| b.* = std.atomic.Value(u64).init(0);
        return m;
    }

    pub fn deinit(_: *PrometheusMetrics) void {}

    /// No-op: counters are always registered implicitly.
    pub fn registerCounter(_: *PrometheusMetrics, _: []const u8, _: []const u8) !void {}

    pub fn recordMessageIn(self: *PrometheusMetrics, count: u64) void {
        _ = self.messages_in.fetchAdd(count, .monotonic);
    }

    pub fn recordMessageOut(self: *PrometheusMetrics, count: u64) void {
        _ = self.messages_out.fetchAdd(count, .monotonic);
    }

    pub fn recordBytesIn(self: *PrometheusMetrics, n: u64) void {
        _ = self.bytes_in.fetchAdd(n, .monotonic);
    }

    pub fn recordBytesOut(self: *PrometheusMetrics, n: u64) void {
        _ = self.bytes_out.fetchAdd(n, .monotonic);
    }

    pub fn recordConnection(self: *PrometheusMetrics) void {
        _ = self.connections.fetchAdd(1, .monotonic);
    }

    pub fn recordError(self: *PrometheusMetrics) void {
        _ = self.errors_total.fetchAdd(1, .monotonic);
    }

    /// Record a publish latency sample (topic ignored; add per-topic map if needed later).
    pub fn recordLatency(self: *PrometheusMetrics, _: []const u8, latency_ns: i64) void {
        if (latency_ns <= 0) return;
        const us: u64 = @intCast(@divTrunc(latency_ns, 1_000));
        _ = self.lat_sum_us.fetchAdd(us, .monotonic);
        _ = self.lat_count.fetchAdd(1, .monotonic);
        // Increment all buckets whose upper bound >= us (cumulative histogram)
        inline for (LAT_BUCKETS_US, 0..) |bound, i| {
            if (us <= bound) _ = self.lat_buckets[i].fetchAdd(1, .monotonic);
        }
        // +Inf bucket always
        _ = self.lat_buckets[N_BUCKETS - 1].fetchAdd(1, .monotonic);
    }

    /// Serialise all metrics to Prometheus text exposition format.
    /// Caller owns the returned slice.
    pub fn renderText(self: *PrometheusMetrics, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        const w = buf.writer();
        try w.print(
            \\# HELP broker_messages_in_total Messages received by the broker
            \\# TYPE broker_messages_in_total counter
            \\broker_messages_in_total {d}
            \\# HELP broker_messages_out_total Messages delivered to consumers
            \\# TYPE broker_messages_out_total counter
            \\broker_messages_out_total {d}
            \\# HELP broker_bytes_in_total Bytes received
            \\# TYPE broker_bytes_in_total counter
            \\broker_bytes_in_total {d}
            \\# HELP broker_bytes_out_total Bytes sent
            \\# TYPE broker_bytes_out_total counter
            \\broker_bytes_out_total {d}
            \\# HELP broker_connections_total Accepted TCP connections
            \\# TYPE broker_connections_total counter
            \\broker_connections_total {d}
            \\# HELP broker_errors_total Errors encountered
            \\# TYPE broker_errors_total counter
            \\broker_errors_total {d}
            \\
        , .{
            self.messages_in.load(.monotonic),
            self.messages_out.load(.monotonic),
            self.bytes_in.load(.monotonic),
            self.bytes_out.load(.monotonic),
            self.connections.load(.monotonic),
            self.errors_total.load(.monotonic),
        });
        try w.writeAll("# HELP broker_publish_latency_microseconds End-to-end publish latency\n");
        try w.writeAll("# TYPE broker_publish_latency_microseconds histogram\n");
        inline for (LAT_BUCKETS_US, 0..) |bound, i| {
            try w.print("broker_publish_latency_microseconds_bucket{{le=\"{d}\"}} {d}\n",
                .{ bound, self.lat_buckets[i].load(.monotonic) });
        }
        try w.print("broker_publish_latency_microseconds_bucket{{le=\"+Inf\"}} {d}\n",
            .{self.lat_buckets[N_BUCKETS - 1].load(.monotonic)});
        try w.print("broker_publish_latency_microseconds_sum {d}\n",
            .{self.lat_sum_us.load(.monotonic)});
        try w.print("broker_publish_latency_microseconds_count {d}\n",
            .{self.lat_count.load(.monotonic)});
        return buf.toOwnedSlice();
    }
};

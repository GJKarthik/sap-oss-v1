//! Prometheus Metrics HTTP Server
//! Production-grade /metrics endpoint for Kubernetes scraping
//! Serves metrics in Prometheus text exposition format

const std = @import("std");
const prometheus = @import("prometheus.zig");

const log = std.log.scoped(.metrics_http);

// ============================================================================
// HTTP Server Configuration
// ============================================================================

pub const HttpServerConfig = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 9090,
    read_timeout_ms: u32 = 5000,
    write_timeout_ms: u32 = 5000,
    max_connections: u32 = 100,
    enable_gzip: bool = true,
};

// ============================================================================
// Prometheus HTTP Server
// ============================================================================

pub const PrometheusHttpServer = struct {
    allocator: std.mem.Allocator,
    config: HttpServerConfig,
    registry: *MetricsRegistry,
    server: ?std.net.Server,
    is_running: std.atomic.Value(bool),
    thread: ?std.Thread,
    total_requests: std.atomic.Value(u64),
    total_errors: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, config: HttpServerConfig, registry: *MetricsRegistry) PrometheusHttpServer {
        return .{
            .allocator = allocator,
            .config = config,
            .registry = registry,
            .server = null,
            .is_running = std.atomic.Value(bool).init(false),
            .thread = null,
            .total_requests = std.atomic.Value(u64).init(0),
            .total_errors = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *PrometheusHttpServer) void {
        self.stop();
    }

    pub fn start(self: *PrometheusHttpServer) !void {
        if (self.is_running.load(.acquire)) return;

        const address = try std.net.Address.parseIp4(self.config.host, self.config.port);
        self.server = try address.listen(.{
            .reuse_address = true,
        });

        self.is_running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, serverLoop, .{self});

        log.info("Prometheus metrics server started on {s}:{}", .{ self.config.host, self.config.port });
    }

    pub fn stop(self: *PrometheusHttpServer) void {
        if (!self.is_running.load(.acquire)) return;

        self.is_running.store(false, .release);

        if (self.server) |*server| {
            server.deinit();
            self.server = null;
        }

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        log.info("Prometheus metrics server stopped", .{});
    }

    fn serverLoop(self: *PrometheusHttpServer) void {
        while (self.is_running.load(.acquire)) {
            const connection = self.server.?.accept() catch |err| {
                if (err == error.SocketNotListening) break;
                log.warn("Failed to accept connection: {}", .{err});
                continue;
            };

            self.handleConnection(connection) catch |err| {
                log.warn("Error handling connection: {}", .{err});
                _ = self.total_errors.fetchAdd(1, .monotonic);
            };
        }
    }

    fn handleConnection(self: *PrometheusHttpServer, connection: std.net.Server.Connection) !void {
        defer connection.stream.close();

        var buf: [4096]u8 = undefined;
        const bytes_read = try connection.stream.read(&buf);

        if (bytes_read == 0) return;

        const request = buf[0..bytes_read];

        // Parse HTTP request
        if (std.mem.startsWith(u8, request, "GET /metrics")) {
            try self.handleMetricsRequest(connection.stream);
            _ = self.total_requests.fetchAdd(1, .monotonic);
        } else if (std.mem.startsWith(u8, request, "GET /health")) {
            try self.handleHealthRequest(connection.stream);
        } else if (std.mem.startsWith(u8, request, "GET /ready")) {
            try self.handleReadyRequest(connection.stream);
        } else {
            try self.handleNotFound(connection.stream);
        }
    }

    fn handleMetricsRequest(self: *PrometheusHttpServer, stream: std.net.Stream) !void {
        // Generate metrics in Prometheus text format
        var buffer: std.ArrayList(u8) = .{};
        defer buffer.deinit(self.allocator);

        try self.registry.writePrometheusFormat(buffer.writer(self.allocator));

        // Add server's own metrics
        var writer = buffer.writer(self.allocator);
        try writer.print(
            \\# HELP prometheus_http_requests_total Total HTTP requests to /metrics
            \\# TYPE prometheus_http_requests_total counter
            \\prometheus_http_requests_total {d}
            \\# HELP prometheus_http_errors_total Total HTTP errors
            \\# TYPE prometheus_http_errors_total counter
            \\prometheus_http_errors_total {d}
            \\
        , .{
            self.total_requests.load(.monotonic),
            self.total_errors.load(.monotonic),
        });

        // Send HTTP response
        const response = try std.fmt.allocPrint(self.allocator,
            \\HTTP/1.1 200 OK
            \\Content-Type: text/plain; version=0.0.4; charset=utf-8
            \\Content-Length: {d}
            \\Connection: close
            \\
            \\{s}
        , .{ buffer.items.len, buffer.items });
        defer self.allocator.free(response);

        _ = try stream.write(response);
    }

    fn handleHealthRequest(self: *PrometheusHttpServer, stream: std.net.Stream) !void {
        _ = self;
        const response =
            \\HTTP/1.1 200 OK
            \\Content-Type: application/json
            \\Content-Length: 15
            \\Connection: close
            \\
            \\{"status":"ok"}
        ;
        _ = try stream.write(response);
    }

    fn handleReadyRequest(self: *PrometheusHttpServer, stream: std.net.Stream) !void {
        const is_ready = self.registry.isHealthy();
        if (is_ready) {
            const response =
                \\HTTP/1.1 200 OK
                \\Content-Type: application/json
                \\Content-Length: 18
                \\Connection: close
                \\
                \\{"ready":"true"}
            ;
            _ = try stream.write(response);
        } else {
            const response =
                \\HTTP/1.1 503 Service Unavailable
                \\Content-Type: application/json
                \\Content-Length: 19
                \\Connection: close
                \\
                \\{"ready":"false"}
            ;
            _ = try stream.write(response);
        }
    }

    fn handleNotFound(self: *PrometheusHttpServer, stream: std.net.Stream) !void {
        _ = self;
        const response =
            \\HTTP/1.1 404 Not Found
            \\Content-Type: text/plain
            \\Content-Length: 9
            \\Connection: close
            \\
            \\Not Found
        ;
        _ = try stream.write(response);
    }
};

// ============================================================================
// Metrics Registry
// ============================================================================

pub const MetricsRegistry = struct {
    allocator: std.mem.Allocator,
    counters: std.StringHashMap(*Counter),
    gauges: std.StringHashMap(*Gauge),
    histograms: std.StringHashMap(*Histogram),
    mutex: std.Thread.Mutex,
    namespace: []const u8,
    subsystem: []const u8,

    pub fn init(allocator: std.mem.Allocator, namespace: []const u8, subsystem: []const u8) MetricsRegistry {
        return .{
            .allocator = allocator,
            .counters = std.StringHashMap(*Counter).init(allocator),
            .gauges = std.StringHashMap(*Gauge).init(allocator),
            .histograms = std.StringHashMap(*Histogram).init(allocator),
            .mutex = .{},
            .namespace = namespace,
            .subsystem = subsystem,
        };
    }

    pub fn deinit(self: *MetricsRegistry) void {
        var counter_iter = self.counters.iterator();
        while (counter_iter.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.counters.deinit();

        var gauge_iter = self.gauges.iterator();
        while (gauge_iter.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.gauges.deinit();

        var hist_iter = self.histograms.iterator();
        while (hist_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
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
        const key = try self.allocator.dupe(u8, name);
        try self.counters.put(key, counter);
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
        const key = try self.allocator.dupe(u8, name);
        try self.gauges.put(key, gauge);
        return gauge;
    }

    pub fn registerHistogram(self: *MetricsRegistry, name: []const u8, help: []const u8, buckets: []const f64) !*Histogram {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.histograms.get(name)) |existing| {
            return existing;
        }

        const histogram = try self.allocator.create(Histogram);
        histogram.* = try Histogram.init(self.allocator, name, help, buckets);
        const key = try self.allocator.dupe(u8, name);
        try self.histograms.put(key, histogram);
        return histogram;
    }

    pub fn writePrometheusFormat(self: *MetricsRegistry, writer: anytype) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Write counters
        var counter_iter = self.counters.iterator();
        while (counter_iter.next()) |entry| {
            const counter = entry.value_ptr.*;
            try writer.print("# HELP {s}_{s}_{s} {s}\n", .{ self.namespace, self.subsystem, counter.name, counter.help });
            try writer.print("# TYPE {s}_{s}_{s} counter\n", .{ self.namespace, self.subsystem, counter.name });
            try writer.print("{s}_{s}_{s} {d}\n", .{ self.namespace, self.subsystem, counter.name, counter.value.load(.monotonic) });
        }

        // Write gauges
        var gauge_iter = self.gauges.iterator();
        while (gauge_iter.next()) |entry| {
            const gauge = entry.value_ptr.*;
            try writer.print("# HELP {s}_{s}_{s} {s}\n", .{ self.namespace, self.subsystem, gauge.name, gauge.help });
            try writer.print("# TYPE {s}_{s}_{s} gauge\n", .{ self.namespace, self.subsystem, gauge.name });
            try writer.print("{s}_{s}_{s} {d}\n", .{ self.namespace, self.subsystem, gauge.name, @as(f64, @floatFromInt(gauge.value.load(.monotonic))) / 1000.0 });
        }

        // Write histograms
        var hist_iter = self.histograms.iterator();
        while (hist_iter.next()) |entry| {
            const histogram = entry.value_ptr.*;
            try writer.print("# HELP {s}_{s}_{s} {s}\n", .{ self.namespace, self.subsystem, histogram.name, histogram.help });
            try writer.print("# TYPE {s}_{s}_{s} histogram\n", .{ self.namespace, self.subsystem, histogram.name });

            var cumulative: u64 = 0;
            for (histogram.buckets, 0..) |bucket, i| {
                cumulative += histogram.bucket_counts[i].load(.monotonic);
                try writer.print("{s}_{s}_{s}_bucket{{le=\"{d:.3}\"}} {d}\n", .{
                    self.namespace,
                    self.subsystem,
                    histogram.name,
                    bucket,
                    cumulative,
                });
            }
            cumulative += histogram.bucket_counts[histogram.buckets.len].load(.monotonic);
            try writer.print("{s}_{s}_{s}_bucket{{le=\"+Inf\"}} {d}\n", .{ self.namespace, self.subsystem, histogram.name, cumulative });
            try writer.print("{s}_{s}_{s}_sum {d:.6}\n", .{ self.namespace, self.subsystem, histogram.name, @as(f64, @floatFromInt(histogram.sum.load(.monotonic))) / 1_000_000.0 });
            try writer.print("{s}_{s}_{s}_count {d}\n", .{ self.namespace, self.subsystem, histogram.name, histogram.count.load(.monotonic) });
        }
    }

    pub fn isHealthy(self: *MetricsRegistry) bool {
        _ = self;
        return true; // Can be extended to check actual health conditions
    }
};

// ============================================================================
// Metric Types
// ============================================================================

pub const Counter = struct {
    name: []const u8,
    help: []const u8,
    value: std.atomic.Value(u64),

    pub fn init(name: []const u8, help: []const u8) Counter {
        return .{
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
};

pub const Gauge = struct {
    name: []const u8,
    help: []const u8,
    value: std.atomic.Value(i64),

    pub fn init(name: []const u8, help: []const u8) Gauge {
        return .{
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
};

pub const Histogram = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    help: []const u8,
    buckets: []const f64,
    bucket_counts: []std.atomic.Value(u64),
    sum: std.atomic.Value(i64),
    count: std.atomic.Value(u64),

    // Default bucket boundaries (in seconds)
    pub const DEFAULT_BUCKETS = [_]f64{ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0 };

    pub fn init(allocator: std.mem.Allocator, name: []const u8, help: []const u8, buckets: []const f64) !Histogram {
        // +1 for +Inf bucket
        const bucket_counts = try allocator.alloc(std.atomic.Value(u64), buckets.len + 1);
        for (bucket_counts) |*bc| {
            bc.* = std.atomic.Value(u64).init(0);
        }

        return .{
            .allocator = allocator,
            .name = name,
            .help = help,
            .buckets = buckets,
            .bucket_counts = bucket_counts,
            .sum = std.atomic.Value(i64).init(0),
            .count = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *Histogram) void {
        self.allocator.free(self.bucket_counts);
    }

    pub fn observe(self: *Histogram, value: f64) void {
        // Find the appropriate bucket
        var bucket_idx: usize = self.buckets.len;
        for (self.buckets, 0..) |bound, i| {
            if (value <= bound) {
                bucket_idx = i;
                break;
            }
        }

        // Increment bucket count
        _ = self.bucket_counts[bucket_idx].fetchAdd(1, .monotonic);

        // Update sum and count (sum is stored as microseconds)
        const value_us: i64 = @intFromFloat(value * 1_000_000);
        _ = self.sum.fetchAdd(value_us, .monotonic);
        _ = self.count.fetchAdd(1, .monotonic);
    }

    pub fn observeDuration(self: *Histogram, start_ns: i128) void {
        const end_ns = std.time.nanoTimestamp();
        const duration_s = @as(f64, @floatFromInt(end_ns - start_ns)) / 1_000_000_000.0;
        self.observe(duration_s);
    }
};

// ============================================================================
// Standard Broker Metrics
// ============================================================================

pub const BrokerMetrics = struct {
    registry: *MetricsRegistry,

    // Connection metrics
    connections_total: *Counter,
    connections_active: *Gauge,
    
    // Message metrics
    messages_received_total: *Counter,
    messages_sent_total: *Counter,
    messages_published_total: *Counter,
    messages_acknowledged_total: *Counter,
    
    // Byte metrics
    bytes_received_total: *Counter,
    bytes_sent_total: *Counter,
    
    // Latency metrics
    publish_latency: *Histogram,
    consume_latency: *Histogram,
    
    // Topic metrics
    topics_count: *Gauge,
    subscriptions_count: *Gauge,
    
    // Storage metrics
    ledger_entries_total: *Counter,
    ledger_size_bytes: *Gauge,
    
    // HANA metrics
    hana_queries_total: *Counter,
    hana_query_latency: *Histogram,
    hana_connections_active: *Gauge,
    hana_errors_total: *Counter,

    pub fn init(allocator: std.mem.Allocator) !BrokerMetrics {
        const registry = try allocator.create(MetricsRegistry);
        registry.* = MetricsRegistry.init(allocator, "aiprompt", "broker");

        return .{
            .registry = registry,
            .connections_total = try registry.registerCounter("connections_total", "Total number of connections established"),
            .connections_active = try registry.registerGauge("connections_active", "Number of active connections"),
            .messages_received_total = try registry.registerCounter("messages_received_total", "Total messages received"),
            .messages_sent_total = try registry.registerCounter("messages_sent_total", "Total messages sent"),
            .messages_published_total = try registry.registerCounter("messages_published_total", "Total messages published"),
            .messages_acknowledged_total = try registry.registerCounter("messages_acknowledged_total", "Total messages acknowledged"),
            .bytes_received_total = try registry.registerCounter("bytes_received_total", "Total bytes received"),
            .bytes_sent_total = try registry.registerCounter("bytes_sent_total", "Total bytes sent"),
            .publish_latency = try registry.registerHistogram("publish_latency_seconds", "Message publish latency in seconds", &Histogram.DEFAULT_BUCKETS),
            .consume_latency = try registry.registerHistogram("consume_latency_seconds", "Message consume latency in seconds", &Histogram.DEFAULT_BUCKETS),
            .topics_count = try registry.registerGauge("topics_count", "Number of topics"),
            .subscriptions_count = try registry.registerGauge("subscriptions_count", "Number of subscriptions"),
            .ledger_entries_total = try registry.registerCounter("ledger_entries_total", "Total ledger entries"),
            .ledger_size_bytes = try registry.registerGauge("ledger_size_bytes", "Total ledger size in bytes"),
            .hana_queries_total = try registry.registerCounter("hana_queries_total", "Total HANA queries executed"),
            .hana_query_latency = try registry.registerHistogram("hana_query_latency_seconds", "HANA query latency in seconds", &Histogram.DEFAULT_BUCKETS),
            .hana_connections_active = try registry.registerGauge("hana_connections_active", "Active HANA connections"),
            .hana_errors_total = try registry.registerCounter("hana_errors_total", "Total HANA errors"),
        };
    }

    pub fn deinit(self: *BrokerMetrics, allocator: std.mem.Allocator) void {
        self.registry.deinit();
        allocator.destroy(self.registry);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Counter operations" {
    var counter = Counter.init("test_counter", "A test counter");
    
    try std.testing.expectEqual(@as(u64, 0), counter.get());
    
    counter.inc();
    try std.testing.expectEqual(@as(u64, 1), counter.get());
    
    counter.add(10);
    try std.testing.expectEqual(@as(u64, 11), counter.get());
}

test "Gauge operations" {
    var gauge = Gauge.init("test_gauge", "A test gauge");
    
    try std.testing.expectEqual(@as(i64, 0), gauge.get());
    
    gauge.set(100);
    try std.testing.expectEqual(@as(i64, 100), gauge.get());
    
    gauge.inc();
    try std.testing.expectEqual(@as(i64, 101), gauge.get());
    
    gauge.dec();
    try std.testing.expectEqual(@as(i64, 100), gauge.get());
}

test "Histogram observe" {
    const allocator = std.testing.allocator;
    var histogram = try Histogram.init(allocator, "test_histogram", "A test histogram", &Histogram.DEFAULT_BUCKETS);
    defer histogram.deinit();
    
    histogram.observe(0.001);
    histogram.observe(0.05);
    histogram.observe(1.0);
    
    try std.testing.expectEqual(@as(u64, 3), histogram.count.load(.monotonic));
}

test "MetricsRegistry" {
    const allocator = std.testing.allocator;
    var registry = MetricsRegistry.init(allocator, "test", "app");
    defer registry.deinit();
    
    const counter = try registry.registerCounter("requests", "Total requests");
    counter.inc();
    
    const gauge = try registry.registerGauge("active", "Active items");
    gauge.set(5);
    
    // Test writing Prometheus format
    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit(allocator);

    try registry.writePrometheusFormat(buffer.writer(allocator));
    try std.testing.expect(buffer.items.len > 0);
}
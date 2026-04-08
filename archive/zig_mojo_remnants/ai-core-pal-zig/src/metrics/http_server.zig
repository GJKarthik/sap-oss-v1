//! BDC MCP PAL - Prometheus Metrics HTTP Server
//! Production /metrics, /health, /ready endpoints for MCP gateway

const std = @import("std");
const log = std.log.scoped(.metrics_http);

pub const McpPalMetrics = struct {
    // MCP Protocol
    mcp_requests_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    mcp_tool_calls: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    mcp_resource_reads: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    mcp_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // PAL Operations
    pal_procedure_calls: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pal_sql_generations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pal_validation_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // HANA
    hana_queries: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    hana_schema_discoveries: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    hana_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // LLM
    llm_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    llm_tokens_used: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    llm_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Gauges
    active_connections: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    registered_tools: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    cached_schemas: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    // Latency
    request_latency_sum: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    request_latency_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pal_latency_sum: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pal_latency_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn recordMcpRequest(self: *McpPalMetrics, latency_ns: u64) void {
        _ = self.mcp_requests_total.fetchAdd(1, .monotonic);
        _ = self.request_latency_sum.fetchAdd(latency_ns, .monotonic);
        _ = self.request_latency_count.fetchAdd(1, .monotonic);
    }

    pub fn recordPalCall(self: *McpPalMetrics, latency_ns: u64) void {
        _ = self.pal_procedure_calls.fetchAdd(1, .monotonic);
        _ = self.pal_latency_sum.fetchAdd(latency_ns, .monotonic);
        _ = self.pal_latency_count.fetchAdd(1, .monotonic);
    }

    pub fn recordToolCall(self: *McpPalMetrics) void {
        _ = self.mcp_tool_calls.fetchAdd(1, .monotonic);
    }

    pub fn recordHanaQuery(self: *McpPalMetrics) void {
        _ = self.hana_queries.fetchAdd(1, .monotonic);
    }

    pub fn recordLlmRequest(self: *McpPalMetrics, tokens: u64) void {
        _ = self.llm_requests.fetchAdd(1, .monotonic);
        _ = self.llm_tokens_used.fetchAdd(tokens, .monotonic);
    }

    pub fn recordError(self: *McpPalMetrics, category: ErrorCategory) void {
        switch (category) {
            .mcp => _ = self.mcp_errors.fetchAdd(1, .monotonic),
            .hana => _ = self.hana_errors.fetchAdd(1, .monotonic),
            .llm => _ = self.llm_errors.fetchAdd(1, .monotonic),
            .pal => _ = self.pal_validation_errors.fetchAdd(1, .monotonic),
        }
    }

    pub const ErrorCategory = enum { mcp, hana, llm, pal };
};

pub const MetricsServer = struct {
    allocator: std.mem.Allocator,
    metrics: *McpPalMetrics,
    server: ?std.net.Server,
    port: u16,
    is_running: std.atomic.Value(bool),
    is_ready: std.atomic.Value(bool),
    thread: ?std.Thread,

    pub fn init(allocator: std.mem.Allocator, metrics: *McpPalMetrics, port: u16) MetricsServer {
        return .{
            .allocator = allocator,
            .metrics = metrics,
            .server = null,
            .port = port,
            .is_running = std.atomic.Value(bool).init(false),
            .is_ready = std.atomic.Value(bool).init(false),
            .thread = null,
        };
    }

    pub fn deinit(self: *MetricsServer) void {
        self.stop();
    }

    pub fn start(self: *MetricsServer) !void {
        if (self.is_running.load(.acquire)) return;

        const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, self.port);
        self.server = try address.listen(.{ .reuse_address = true });
        self.is_running.store(true, .release);

        self.thread = try std.Thread.spawn(.{}, serverLoop, .{self});
        log.info("Metrics server started on port {}", .{self.port});
    }

    pub fn stop(self: *MetricsServer) void {
        if (!self.is_running.swap(false, .acq_rel)) return;
        if (self.server) |*srv| {
            srv.deinit();
            self.server = null;
        }
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn setReady(self: *MetricsServer, ready: bool) void {
        self.is_ready.store(ready, .release);
    }

    fn serverLoop(self: *MetricsServer) void {
        while (self.is_running.load(.acquire)) {
            if (self.server) |*srv| {
                const conn = srv.accept() catch continue;
                self.handleConnection(conn) catch |err| {
                    log.warn("Connection error: {}", .{err});
                };
            }
        }
    }

    fn handleConnection(self: *MetricsServer, conn: std.net.Server.Connection) !void {
        defer conn.stream.close();

        var buf: [4096]u8 = undefined;
        const n = try conn.stream.read(&buf);
        if (n == 0) return;

        const request = buf[0..n];
        if (std.mem.startsWith(u8, request, "GET /metrics")) {
            try self.sendMetrics(conn.stream);
        } else if (std.mem.startsWith(u8, request, "GET /health")) {
            try self.sendHealth(conn.stream);
        } else if (std.mem.startsWith(u8, request, "GET /ready")) {
            try self.sendReady(conn.stream);
        } else {
            try conn.stream.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
        }
    }

    fn sendMetrics(self: *MetricsServer, stream: std.net.Stream) !void {
        var buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();

        // MCP metrics
        try w.print("# HELP mcp_requests_total Total MCP requests\n", .{});
        try w.print("# TYPE mcp_requests_total counter\n", .{});
        try w.print("mcp_requests_total {}\n\n", .{self.metrics.mcp_requests_total.load(.monotonic)});

        try w.print("# HELP mcp_tool_calls_total Total tool calls\n", .{});
        try w.print("# TYPE mcp_tool_calls_total counter\n", .{});
        try w.print("mcp_tool_calls_total {}\n\n", .{self.metrics.mcp_tool_calls.load(.monotonic)});

        try w.print("# HELP mcp_resource_reads_total Total resource reads\n", .{});
        try w.print("# TYPE mcp_resource_reads_total counter\n", .{});
        try w.print("mcp_resource_reads_total {}\n\n", .{self.metrics.mcp_resource_reads.load(.monotonic)});

        // PAL metrics
        try w.print("# HELP pal_procedure_calls_total Total PAL procedure calls\n", .{});
        try w.print("# TYPE pal_procedure_calls_total counter\n", .{});
        try w.print("pal_procedure_calls_total {}\n\n", .{self.metrics.pal_procedure_calls.load(.monotonic)});

        try w.print("# HELP pal_sql_generations_total Total PAL SQL generations\n", .{});
        try w.print("# TYPE pal_sql_generations_total counter\n", .{});
        try w.print("pal_sql_generations_total {}\n\n", .{self.metrics.pal_sql_generations.load(.monotonic)});

        // HANA metrics
        try w.print("# HELP hana_queries_total Total HANA queries\n", .{});
        try w.print("# TYPE hana_queries_total counter\n", .{});
        try w.print("hana_queries_total {}\n\n", .{self.metrics.hana_queries.load(.monotonic)});

        try w.print("# HELP hana_schema_discoveries_total Schema discoveries\n", .{});
        try w.print("# TYPE hana_schema_discoveries_total counter\n", .{});
        try w.print("hana_schema_discoveries_total {}\n\n", .{self.metrics.hana_schema_discoveries.load(.monotonic)});

        // LLM metrics
        try w.print("# HELP llm_requests_total Total LLM requests\n", .{});
        try w.print("# TYPE llm_requests_total counter\n", .{});
        try w.print("llm_requests_total {}\n\n", .{self.metrics.llm_requests.load(.monotonic)});

        try w.print("# HELP llm_tokens_total Total LLM tokens used\n", .{});
        try w.print("# TYPE llm_tokens_total counter\n", .{});
        try w.print("llm_tokens_total {}\n\n", .{self.metrics.llm_tokens_used.load(.monotonic)});

        // Error metrics
        try w.print("# HELP mcp_errors_total Errors by category\n", .{});
        try w.print("# TYPE mcp_errors_total counter\n", .{});
        try w.print("mcp_errors_total{{category=\"mcp\"}} {}\n", .{self.metrics.mcp_errors.load(.monotonic)});
        try w.print("mcp_errors_total{{category=\"hana\"}} {}\n", .{self.metrics.hana_errors.load(.monotonic)});
        try w.print("mcp_errors_total{{category=\"llm\"}} {}\n", .{self.metrics.llm_errors.load(.monotonic)});
        try w.print("mcp_errors_total{{category=\"pal\"}} {}\n\n", .{self.metrics.pal_validation_errors.load(.monotonic)});

        // Gauges
        try w.print("# HELP mcp_active_connections Active connections\n", .{});
        try w.print("# TYPE mcp_active_connections gauge\n", .{});
        try w.print("mcp_active_connections {}\n\n", .{self.metrics.active_connections.load(.monotonic)});

        try w.print("# HELP mcp_registered_tools Registered tools\n", .{});
        try w.print("# TYPE mcp_registered_tools gauge\n", .{});
        try w.print("mcp_registered_tools {}\n\n", .{self.metrics.registered_tools.load(.monotonic)});

        // Latency
        const req_count = self.metrics.request_latency_count.load(.monotonic);
        const req_sum = self.metrics.request_latency_sum.load(.monotonic);
        try w.print("# HELP mcp_request_latency_seconds Request latency\n", .{});
        try w.print("# TYPE mcp_request_latency_seconds summary\n", .{});
        try w.print("mcp_request_latency_seconds_sum {d:.6}\n", .{@as(f64, @floatFromInt(req_sum)) / 1e9});
        try w.print("mcp_request_latency_seconds_count {}\n\n", .{req_count});

        const pal_count = self.metrics.pal_latency_count.load(.monotonic);
        const pal_sum = self.metrics.pal_latency_sum.load(.monotonic);
        try w.print("# HELP pal_call_latency_seconds PAL call latency\n", .{});
        try w.print("# TYPE pal_call_latency_seconds summary\n", .{});
        try w.print("pal_call_latency_seconds_sum {d:.6}\n", .{@as(f64, @floatFromInt(pal_sum)) / 1e9});
        try w.print("pal_call_latency_seconds_count {}\n", .{pal_count});

        const body = fbs.getWritten();
        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: {}\r\n\r\n", .{body.len}) catch return;

        try stream.writeAll(header);
        try stream.writeAll(body);
    }

    fn sendHealth(self: *MetricsServer, stream: std.net.Stream) !void {
        _ = self;
        try stream.writeAll("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 15\r\n\r\n{\"status\":\"ok\"}");
    }

    fn sendReady(self: *MetricsServer, stream: std.net.Stream) !void {
        if (self.is_ready.load(.acquire)) {
            try stream.writeAll("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 18\r\n\r\n{\"status\":\"ready\"}");
        } else {
            try stream.writeAll("HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: 22\r\n\r\n{\"status\":\"not_ready\"}");
        }
    }
};

test "McpPalMetrics recording" {
    var metrics = McpPalMetrics{};
    metrics.recordMcpRequest(1000);
    metrics.recordToolCall();
    metrics.recordPalCall(500);
    metrics.recordHanaQuery();

    try std.testing.expectEqual(@as(u64, 1), metrics.mcp_requests_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), metrics.mcp_tool_calls.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), metrics.pal_procedure_calls.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), metrics.hana_queries.load(.monotonic));
}
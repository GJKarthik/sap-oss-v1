//! Deductive DB HTTP Client for Metrics and Logs Replication
//!
//! Provides CRUD operations for replicating inference metrics, model usage,
//! and Mangle rule evaluations to the deductive-db service via Neo4j HTTP API.

const std = @import("std");
const net = std.net;
const Allocator = std.mem.Allocator;
const posix = std.posix;

// ============================================================================
// Data Types for Metrics/Logs
// ============================================================================

pub const InferenceMetric = struct {
    request_id: []const u8,
    model_id: []const u8,
    intent: []const u8,
    latency_ms: u64,
    tokens_in: u32,
    tokens_out: u32,
    temperature: f32,
    timestamp: i64,
};

pub const ModelUsageLog = struct {
    model_id: []const u8,
    event_type: []const u8, // "load", "unload", "infer", "error"
    memory_mb: u32,
    gpu_utilization: f32,
    layer_count_loaded: u32,
    timestamp: i64,
    details: ?[]const u8,
};

pub const MangleRuleEvaluation = struct {
    rule_file: []const u8,
    rule_name: []const u8,
    input_intent: []const u8,
    output_model: []const u8,
    output_temperature: f32,
    evaluation_time_us: u64,
    success: bool,
    timestamp: i64,
};

pub const LogEntry = struct {
    level: []const u8, // "DEBUG", "INFO", "WARN", "ERROR"
    component: []const u8,
    message: []const u8,
    request_id: ?[]const u8,
    model_id: ?[]const u8,
    timestamp: i64,
};

// ============================================================================
// Neo4j HTTP Client for Deductive DB
// ============================================================================

pub const DeductiveDbClient = struct {
    allocator: Allocator,
    base_url: []const u8,
    database: []const u8,
    auth_header: ?[]const u8,
    service_name: []const u8,

    const Self = @This();

    pub fn init(allocator: Allocator, base_url: []const u8, database: []const u8, service_name: []const u8) !Self {
        return Self{
            .allocator = allocator,
            .base_url = base_url,
            .database = database,
            .auth_header = null,
            .service_name = service_name,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.auth_header) |h| {
            self.allocator.free(h);
        }
    }

    pub fn setBasicAuth(self: *Self, username: []const u8, password: []const u8) !void {
        // Free previous auth header if set (avoid leak on repeated calls)
        if (self.auth_header) |old| self.allocator.free(old);
        self.auth_header = null;

        const auth = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ username, password });
        defer self.allocator.free(auth);

        // Dynamically size the base64 buffer to avoid overflow with long credentials
        const encoder = std.base64.standard.Encoder;
        const encoded_len = encoder.calcSize(auth.len);
        const encoded_buf = try self.allocator.alloc(u8, encoded_len);
        defer self.allocator.free(encoded_buf);
        const encoded_slice = encoder.encode(encoded_buf, auth);

        self.auth_header = try std.fmt.allocPrint(self.allocator, "Basic {s}", .{encoded_slice});
    }

    // ========================================================================
    // CRUD Operations - Create
    // ========================================================================

    /// Create an inference metric node
    pub fn createInferenceMetric(self: *Self, metric: InferenceMetric) ![]const u8 {
        const esc_request_id = try self.escapeCypherValue(metric.request_id);
        defer self.allocator.free(esc_request_id);
        const esc_model_id = try self.escapeCypherValue(metric.model_id);
        defer self.allocator.free(esc_model_id);
        const esc_intent = try self.escapeCypherValue(metric.intent);
        defer self.allocator.free(esc_intent);
        const esc_service = try self.escapeCypherValue(self.service_name);
        defer self.allocator.free(esc_service);

        const cypher = try std.fmt.allocPrint(self.allocator,
            \\CREATE (m:InferenceMetric {{
            \\  request_id: '{s}',
            \\  model_id: '{s}',
            \\  intent: '{s}',
            \\  latency_ms: {d},
            \\  tokens_in: {d},
            \\  tokens_out: {d},
            \\  temperature: {d:.3},
            \\  timestamp: {d},
            \\  service: '{s}'
            \\}})
            \\RETURN m
        , .{
            esc_request_id,
            esc_model_id,
            esc_intent,
            metric.latency_ms,
            metric.tokens_in,
            metric.tokens_out,
            metric.temperature,
            metric.timestamp,
            esc_service,
        });
        defer self.allocator.free(cypher);

        return self.executeCypher(cypher);
    }

    /// Create a model usage log node with relationship to model
    pub fn createModelUsageLog(self: *Self, log: ModelUsageLog) ![]const u8 {
        const esc_model_id = try self.escapeCypherValue(log.model_id);
        defer self.allocator.free(esc_model_id);
        const esc_event_type = try self.escapeCypherValue(log.event_type);
        defer self.allocator.free(esc_event_type);
        const esc_details = try self.escapeCypherValue(log.details orelse "");
        defer self.allocator.free(esc_details);
        const esc_service = try self.escapeCypherValue(self.service_name);
        defer self.allocator.free(esc_service);

        const cypher = try std.fmt.allocPrint(self.allocator,
            \\MERGE (model:Model {{ id: '{s}' }})
            \\CREATE (log:ModelUsageLog {{
            \\  model_id: '{s}',
            \\  event_type: '{s}',
            \\  memory_mb: {d},
            \\  gpu_utilization: {d:.3},
            \\  layer_count_loaded: {d},
            \\  timestamp: {d},
            \\  details: '{s}',
            \\  service: '{s}'
            \\}})
            \\CREATE (model)-[:HAS_USAGE_LOG]->(log)
            \\RETURN log
        , .{
            esc_model_id,
            esc_model_id,
            esc_event_type,
            log.memory_mb,
            log.gpu_utilization,
            log.layer_count_loaded,
            log.timestamp,
            esc_details,
            esc_service,
        });
        defer self.allocator.free(cypher);

        return self.executeCypher(cypher);
    }

    /// Create a Mangle rule evaluation node
    pub fn createMangleEvaluation(self: *Self, eval: MangleRuleEvaluation) ![]const u8 {
        const esc_rule_file = try self.escapeCypherValue(eval.rule_file);
        defer self.allocator.free(esc_rule_file);
        const esc_rule_name = try self.escapeCypherValue(eval.rule_name);
        defer self.allocator.free(esc_rule_name);
        const esc_input_intent = try self.escapeCypherValue(eval.input_intent);
        defer self.allocator.free(esc_input_intent);
        const esc_output_model = try self.escapeCypherValue(eval.output_model);
        defer self.allocator.free(esc_output_model);
        const esc_service = try self.escapeCypherValue(self.service_name);
        defer self.allocator.free(esc_service);

        const cypher = try std.fmt.allocPrint(self.allocator,
            \\MERGE (rule:MangleRule {{ file: '{s}', name: '{s}' }})
            \\CREATE (eval:MangleEvaluation {{
            \\  rule_file: '{s}',
            \\  rule_name: '{s}',
            \\  input_intent: '{s}',
            \\  output_model: '{s}',
            \\  output_temperature: {d:.3},
            \\  evaluation_time_us: {d},
            \\  success: {s},
            \\  timestamp: {d},
            \\  service: '{s}'
            \\}})
            \\CREATE (rule)-[:EVALUATED_AS]->(eval)
            \\RETURN eval
        , .{
            esc_rule_file,
            esc_rule_name,
            esc_rule_file,
            esc_rule_name,
            esc_input_intent,
            esc_output_model,
            eval.output_temperature,
            eval.evaluation_time_us,
            if (eval.success) "true" else "false",
            eval.timestamp,
            esc_service,
        });
        defer self.allocator.free(cypher);

        return self.executeCypher(cypher);
    }

    /// Create a log entry node
    pub fn createLogEntry(self: *Self, entry: LogEntry) ![]const u8 {
        const esc_level = try self.escapeCypherValue(entry.level);
        defer self.allocator.free(esc_level);
        const esc_component = try self.escapeCypherValue(entry.component);
        defer self.allocator.free(esc_component);
        const esc_msg = try self.escapeCypherValue(entry.message);
        defer self.allocator.free(esc_msg);
        const esc_request_id = try self.escapeCypherValue(entry.request_id orelse "");
        defer self.allocator.free(esc_request_id);
        const esc_model_id = try self.escapeCypherValue(entry.model_id orelse "");
        defer self.allocator.free(esc_model_id);
        const esc_service = try self.escapeCypherValue(self.service_name);
        defer self.allocator.free(esc_service);

        const cypher = try std.fmt.allocPrint(self.allocator,
            \\CREATE (log:LogEntry {{
            \\  level: '{s}',
            \\  component: '{s}',
            \\  message: '{s}',
            \\  request_id: '{s}',
            \\  model_id: '{s}',
            \\  timestamp: {d},
            \\  service: '{s}'
            \\}})
            \\RETURN log
        , .{
            esc_level,
            esc_component,
            esc_msg,
            esc_request_id,
            esc_model_id,
            entry.timestamp,
            esc_service,
        });
        defer self.allocator.free(cypher);

        return self.executeCypher(cypher);
    }

    // ========================================================================
    // CRUD Operations - Read
    // ========================================================================

    /// Get inference metrics for a model within a time range
    pub fn getInferenceMetrics(self: *Self, model_id: []const u8, start_ts: i64, end_ts: i64) ![]const u8 {
        const cypher = try std.fmt.allocPrint(self.allocator,
            \\MATCH (m:InferenceMetric)
            \\WHERE m.model_id = '{s}'
            \\  AND m.timestamp >= {d}
            \\  AND m.timestamp <= {d}
            \\RETURN m
            \\ORDER BY m.timestamp DESC
        , .{ model_id, start_ts, end_ts });
        defer self.allocator.free(cypher);

        return self.executeCypher(cypher);
    }

    /// Get model usage logs by event type
    pub fn getModelUsageLogs(self: *Self, model_id: []const u8, event_type: ?[]const u8) ![]const u8 {
        const cypher = if (event_type) |et|
            try std.fmt.allocPrint(self.allocator,
                \\MATCH (m:Model {{ id: '{s}' }})-[:HAS_USAGE_LOG]->(log:ModelUsageLog)
                \\WHERE log.event_type = '{s}'
                \\RETURN log
                \\ORDER BY log.timestamp DESC
            , .{ model_id, et })
        else
            try std.fmt.allocPrint(self.allocator,
                \\MATCH (m:Model {{ id: '{s}' }})-[:HAS_USAGE_LOG]->(log:ModelUsageLog)
                \\RETURN log
                \\ORDER BY log.timestamp DESC
            , .{model_id});
        defer self.allocator.free(cypher);

        return self.executeCypher(cypher);
    }

    /// Get Mangle rule evaluations
    pub fn getMangleEvaluations(self: *Self, rule_file: ?[]const u8, limit: u32) ![]const u8 {
        const cypher = if (rule_file) |rf|
            try std.fmt.allocPrint(self.allocator,
                \\MATCH (eval:MangleEvaluation)
                \\WHERE eval.rule_file = '{s}'
                \\RETURN eval
                \\ORDER BY eval.timestamp DESC
                \\LIMIT {d}
            , .{ rf, limit })
        else
            try std.fmt.allocPrint(self.allocator,
                \\MATCH (eval:MangleEvaluation)
                \\RETURN eval
                \\ORDER BY eval.timestamp DESC
                \\LIMIT {d}
            , .{limit});
        defer self.allocator.free(cypher);

        return self.executeCypher(cypher);
    }

    /// Get recent log entries by level
    pub fn getLogEntries(self: *Self, level: ?[]const u8, component: ?[]const u8, limit: u32) ![]const u8 {
        var conditions = std.ArrayListUnmanaged(u8){};
        var writer = conditions.writer();
        defer conditions.deinit();

        try writer.writeAll("WHERE 1=1");
        if (level) |l| {
            const esc_level = try self.escapeCypherValue(l);
            defer self.allocator.free(esc_level);
            try writer.print(" AND log.level = '{s}'", .{esc_level});
        }
        if (component) |c| {
            const esc_component = try self.escapeCypherValue(c);
            defer self.allocator.free(esc_component);
            try writer.print(" AND log.component = '{s}'", .{esc_component});
        }

        const cypher = try std.fmt.allocPrint(self.allocator,
            \\MATCH (log:LogEntry)
            \\{s}
            \\RETURN log
            \\ORDER BY log.timestamp DESC
            \\LIMIT {d}
        , .{ conditions.items, limit });
        defer self.allocator.free(cypher);

        return self.executeCypher(cypher);
    }

    /// Get aggregate metrics for a model
    pub fn getModelMetricsAggregate(self: *Self, model_id: []const u8) ![]const u8 {
        const cypher = try std.fmt.allocPrint(self.allocator,
            \\MATCH (m:InferenceMetric {{ model_id: '{s}' }})
            \\RETURN 
            \\  count(m) as total_requests,
            \\  avg(m.latency_ms) as avg_latency_ms,
            \\  sum(m.tokens_in) as total_tokens_in,
            \\  sum(m.tokens_out) as total_tokens_out,
            \\  min(m.timestamp) as first_request,
            \\  max(m.timestamp) as last_request
        , .{model_id});
        defer self.allocator.free(cypher);

        return self.executeCypher(cypher);
    }

    // ========================================================================
    // CRUD Operations - Update
    // ========================================================================

    /// Update model node with latest stats
    pub fn updateModelStats(self: *Self, model_id: []const u8, total_inferences: u64, avg_latency_ms: f64) ![]const u8 {
        const cypher = try std.fmt.allocPrint(self.allocator,
            \\MERGE (m:Model {{ id: '{s}' }})
            \\SET m.total_inferences = {d},
            \\    m.avg_latency_ms = {d:.3},
            \\    m.last_updated = timestamp()
            \\RETURN m
        , .{ model_id, total_inferences, avg_latency_ms });
        defer self.allocator.free(cypher);

        return self.executeCypher(cypher);
    }

    /// Update Mangle rule stats
    pub fn updateMangleRuleStats(self: *Self, rule_file: []const u8, rule_name: []const u8, total_evals: u64, success_rate: f64) ![]const u8 {
        const cypher = try std.fmt.allocPrint(self.allocator,
            \\MERGE (r:MangleRule {{ file: '{s}', name: '{s}' }})
            \\SET r.total_evaluations = {d},
            \\    r.success_rate = {d:.3},
            \\    r.last_updated = timestamp()
            \\RETURN r
        , .{ rule_file, rule_name, total_evals, success_rate });
        defer self.allocator.free(cypher);

        return self.executeCypher(cypher);
    }

    // ========================================================================
    // CRUD Operations - Delete
    // ========================================================================

    /// Delete old metrics (older than retention_days)
    pub fn deleteOldMetrics(self: *Self, retention_days: u32) ![]const u8 {
        const retention_ms = @as(i64, retention_days) * 24 * 60 * 60 * 1000;
        const cypher = try std.fmt.allocPrint(self.allocator,
            \\MATCH (m:InferenceMetric)
            \\WHERE m.timestamp < (timestamp() - {d})
            \\DELETE m
            \\RETURN count(m) as deleted_count
        , .{retention_ms});
        defer self.allocator.free(cypher);

        return self.executeCypher(cypher);
    }

    /// Delete old log entries
    pub fn deleteOldLogs(self: *Self, retention_days: u32) ![]const u8 {
        const retention_ms = @as(i64, retention_days) * 24 * 60 * 60 * 1000;
        const cypher = try std.fmt.allocPrint(self.allocator,
            \\MATCH (log:LogEntry)
            \\WHERE log.timestamp < (timestamp() - {d})
            \\DELETE log
            \\RETURN count(log) as deleted_count
        , .{retention_ms});
        defer self.allocator.free(cypher);

        return self.executeCypher(cypher);
    }

    /// Delete a specific model and all related data
    pub fn deleteModel(self: *Self, model_id: []const u8) ![]const u8 {
        const cypher = try std.fmt.allocPrint(self.allocator,
            \\MATCH (m:Model {{ id: '{s}' }})
            \\OPTIONAL MATCH (m)-[r]-()
            \\DELETE r, m
            \\RETURN count(m) as deleted_count
        , .{model_id});
        defer self.allocator.free(cypher);

        return self.executeCypher(cypher);
    }

    // ========================================================================
    // Batch Operations
    // ========================================================================

    /// Batch create multiple inference metrics
    pub fn batchCreateMetrics(self: *Self, metrics: []const InferenceMetric) ![]const u8 {
        var cypher = std.ArrayListUnmanaged(u8){};
        var writer = cypher.writer();
        defer cypher.deinit();

        for (metrics, 0..) |metric, i| {
            const esc_request_id = try self.escapeCypherValue(metric.request_id);
            defer self.allocator.free(esc_request_id);
            const esc_model_id = try self.escapeCypherValue(metric.model_id);
            defer self.allocator.free(esc_model_id);
            const esc_intent = try self.escapeCypherValue(metric.intent);
            defer self.allocator.free(esc_intent);
            const esc_service = try self.escapeCypherValue(self.service_name);
            defer self.allocator.free(esc_service);
            try writer.print(
                \\CREATE (m{d}:InferenceMetric {{
                \\  request_id: '{s}',
                \\  model_id: '{s}',
                \\  intent: '{s}',
                \\  latency_ms: {d},
                \\  tokens_in: {d},
                \\  tokens_out: {d},
                \\  timestamp: {d},
                \\  service: '{s}'
                \\}})
                \\
            , .{
                i,
                esc_request_id,
                esc_model_id,
                esc_intent,
                metric.latency_ms,
                metric.tokens_in,
                metric.tokens_out,
                metric.timestamp,
                esc_service,
            });
        }
        try writer.writeAll("RETURN count(*) as created");

        return self.executeCypher(cypher.items);
    }

    // ========================================================================
    // Schema Setup
    // ========================================================================

    /// Create indexes for efficient querying
    pub fn setupSchema(self: *Self) !void {
        // Create indexes for common queries
        const indexes = [_][]const u8{
            "CREATE INDEX IF NOT EXISTS FOR (m:InferenceMetric) ON (m.model_id)",
            "CREATE INDEX IF NOT EXISTS FOR (m:InferenceMetric) ON (m.timestamp)",
            "CREATE INDEX IF NOT EXISTS FOR (log:LogEntry) ON (log.timestamp)",
            "CREATE INDEX IF NOT EXISTS FOR (log:LogEntry) ON (log.level)",
            "CREATE INDEX IF NOT EXISTS FOR (log:ModelUsageLog) ON (log.model_id)",
            "CREATE INDEX IF NOT EXISTS FOR (eval:MangleEvaluation) ON (eval.rule_file)",
            "CREATE INDEX IF NOT EXISTS FOR (m:Model) ON (m.id)",
        };

        for (indexes) |idx| {
            _ = try self.executeCypher(idx);
        }
    }

    // ========================================================================
    // HTTP Implementation
    // ========================================================================

    fn executeCypher(self: *Self, cypher: []const u8) ![]const u8 {
        const path = try std.fmt.allocPrint(self.allocator, "/db/{s}/tx/commit", .{self.database});
        defer self.allocator.free(path);

        const escaped = try self.escapeString(cypher);
        defer self.allocator.free(escaped);

        const body = try std.fmt.allocPrint(self.allocator,
            \\{{"statements": [{{"statement": "{s}"}}]}}
        , .{escaped});
        defer self.allocator.free(body);

        return self.post(path, body);
    }

    /// Escape a string value for safe inclusion in Cypher single-quoted literals.
    /// Handles single quotes, double quotes, backslashes, and control characters.
    fn escapeCypherValue(self: *Self, input: []const u8) ![]const u8 {
        return self.escapeString(input);
    }

    fn escapeString(self: *Self, input: []const u8) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        var writer = result.writer();

        for (input) |c| {
            switch (c) {
                '\'' => try writer.writeAll("\\'"),
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => try writer.writeByte(c),
            }
        }

        return result.toOwnedSlice();
    }

    fn parseUrl(self: *Self) !struct { host: []const u8, port: u16 } {
        var url = self.base_url;

        if (std.mem.startsWith(u8, url, "https://")) {
            url = url[8..];
        } else if (std.mem.startsWith(u8, url, "http://")) {
            url = url[7..];
        }

        var port: u16 = 7474;
        var host = url;

        if (std.mem.indexOf(u8, url, ":")) |colon_pos| {
            host = url[0..colon_pos];
            const port_str = url[colon_pos + 1 ..];
            port = std.fmt.parseInt(u16, port_str, 10) catch port;
        }

        return .{ .host = host, .port = port };
    }

    fn post(self: *Self, path: []const u8, body: []const u8) ![]const u8 {
        const url_info = try self.parseUrl();

        var request = std.ArrayListUnmanaged(u8){};
        var writer = request.writer();
        defer request.deinit();

        try writer.print("POST {s} HTTP/1.1\r\n", .{path});
        try writer.print("Host: {s}\r\n", .{url_info.host});
        try writer.writeAll("Content-Type: application/json\r\n");
        try writer.writeAll("Accept: application/json\r\n");
        try writer.print("Content-Length: {d}\r\n", .{body.len});
        if (self.auth_header) |auth| {
            try writer.print("Authorization: {s}\r\n", .{auth});
        }
        try writer.writeAll("Connection: close\r\n");
        try writer.writeAll("\r\n");
        try writer.writeAll(body);

        return self.sendRequest(url_info.host, url_info.port, request.items);
    }

    fn sendRequest(self: *Self, host: []const u8, port: u16, request: []const u8) ![]const u8 {
        const address = net.Address.parseIp4(host, port) catch {
            return error.UnableToResolve;
        };

        const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        defer posix.close(sock);

        try posix.connect(sock, &address.any, address.getOsSockLen());
        _ = try posix.write(sock, request);

        var response = std.ArrayListUnmanaged(u8){};
        var buf: [4096]u8 = undefined;

        while (true) {
            const n = posix.read(sock, &buf) catch break;
            if (n == 0) break;
            try response.appendSlice(buf[0..n]);
        }

        // Extract body (after \r\n\r\n)
        const body_start = std.mem.indexOf(u8, response.items, "\r\n\r\n") orelse 0;
        if (body_start > 0) {
            const body_content = response.items[body_start + 4 ..];
            const result = try self.allocator.dupe(u8, body_content);
            response.deinit();
            return result;
        }

        return response.toOwnedSlice();
    }
};

// ============================================================================
// Metrics Collector (Background Service)
// ============================================================================

pub const MetricsCollector = struct {
    allocator: Allocator,
    client: DeductiveDbClient,
    buffer: std.ArrayListUnmanaged(InferenceMetric),
    buffer_size: usize,

    const Self = @This();

    pub fn init(allocator: Allocator, db_url: []const u8, database: []const u8, service_name: []const u8, buffer_size: usize) !Self {
        return Self{
            .allocator = allocator,
            .client = try DeductiveDbClient.init(allocator, db_url, database, service_name),
            .buffer = std.ArrayListUnmanaged(InferenceMetric){},
            .buffer_size = buffer_size,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
        self.client.deinit();
    }

    pub fn recordMetric(self: *Self, metric: InferenceMetric) !void {
        try self.buffer.append(metric);

        if (self.buffer.items.len >= self.buffer_size) {
            try self.flush();
        }
    }

    pub fn flush(self: *Self) !void {
        if (self.buffer.items.len == 0) return;

        _ = try self.client.batchCreateMetrics(self.buffer.items);
        self.buffer.clearRetainingCapacity();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "create inference metric cypher" {
    const allocator = std.testing.allocator;
    var client = try DeductiveDbClient.init(allocator, "http://127.0.0.1:7474", "neo4j", "local-models");
    defer client.deinit();

    // Test would verify Cypher generation
}

test "escape string" {
    const allocator = std.testing.allocator;
    var client = try DeductiveDbClient.init(allocator, "http://127.0.0.1:7474", "neo4j", "test");
    defer client.deinit();

    const escaped = try client.escapeString("Hello\n\"World\"");
    defer allocator.free(escaped);

    try std.testing.expectEqualStrings("Hello\\n\\\"World\\\"", escaped);
}
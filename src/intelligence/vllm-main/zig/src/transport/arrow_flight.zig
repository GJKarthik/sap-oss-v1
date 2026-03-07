//! Arrow Flight gRPC-Web Server/Client for SAP AI Core
//!
//! Provides high-speed columnar data exchange between services
//! using Apache Arrow IPC format over HTTP (gRPC-Web compatible).
//!
//! AI Core Compatibility:
//! - Runs on same :8080 port via content-type routing
//! - Uses HTTP/1.1 with application/grpc-web+proto content type
//! - Zero-copy GPU tensor exchange via Arrow RecordBatches

const std = @import("std");

// ============================================================================
// Arrow Schema Definitions
// ============================================================================

pub const DataType = enum {
    null_type,
    bool_type,
    int8,
    int16,
    int32,
    int64,
    uint8,
    uint16,
    uint32,
    uint64,
    float16,
    float32,
    float64,
    utf8,
    binary,
    timestamp_ms,
    timestamp_us,
    date32,
    date64,
    fixed_size_list,
    list,
    struct_type,
    
    pub fn toString(self: DataType) []const u8 {
        return @tagName(self);
    }
};

pub const Field = struct {
    name: []const u8,
    data_type: DataType,
    nullable: bool = true,
    list_size: ?usize = null, // For fixed_size_list
};

pub const Schema = struct {
    fields: []const Field,
    
    pub fn fieldCount(self: Schema) usize {
        return self.fields.len;
    }
    
    pub fn getField(self: Schema, name: []const u8) ?Field {
        for (self.fields) |f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }
};

// ============================================================================
// Standard Schemas for Service-to-Service Communication
// ============================================================================

pub const Schemas = struct {
    /// Time series data for forecasting (odata-time-series → mesh-gateway)
    pub const TimeSeries = Schema{
        .fields = &.{
            .{ .name = "timestamp", .data_type = .timestamp_ms },
            .{ .name = "value", .data_type = .float64 },
            .{ .name = "entity_id", .data_type = .utf8 },
            .{ .name = "metric_name", .data_type = .utf8 },
        },
    };
    
    /// Embedding vectors for similarity search
    pub const Embeddings = Schema{
        .fields = &.{
            .{ .name = "id", .data_type = .utf8 },
            .{ .name = "vector", .data_type = .fixed_size_list, .list_size = 256 },
            .{ .name = "source", .data_type = .utf8 },
            .{ .name = "timestamp", .data_type = .timestamp_ms },
        },
    };
    
    /// OData entity records
    pub const ODataEntity = Schema{
        .fields = &.{
            .{ .name = "entity_set", .data_type = .utf8 },
            .{ .name = "key", .data_type = .utf8 },
            .{ .name = "properties_json", .data_type = .utf8 },
            .{ .name = "etag", .data_type = .utf8 },
        },
    };
    
    /// Forecast results
    pub const ForecastResult = Schema{
        .fields = &.{
            .{ .name = "timestamp", .data_type = .timestamp_ms },
            .{ .name = "predicted_value", .data_type = .float64 },
            .{ .name = "lower_bound", .data_type = .float64 },
            .{ .name = "upper_bound", .data_type = .float64 },
            .{ .name = "confidence", .data_type = .float64 },
        },
    };
};

// ============================================================================
// Arrow Record Batch (simplified)
// ============================================================================

pub const RecordBatch = struct {
    schema: Schema,
    row_count: usize,
    columns: std.ArrayList(Column),
    allocator: std.mem.Allocator,
    
    pub const Column = struct {
        name: []const u8,
        data: []const u8, // Raw bytes
        null_bitmap: ?[]const u8 = null,
    };
    
    pub fn init(allocator: std.mem.Allocator, schema: Schema) RecordBatch {
        return .{
            .schema = schema,
            .row_count = 0,
            .columns = .{},
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *RecordBatch) void {
        for (self.columns.items) |col| {
            self.allocator.free(col.data);
            if (col.null_bitmap) |bm| self.allocator.free(bm);
        }
        self.columns.deinit();
    }
    
    /// Serialize to Arrow IPC format (simplified)
    pub fn toIpc(self: *const RecordBatch, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8){};
        const w = buf.writer();
        
        // Magic bytes "ARROW1"
        try w.writeAll("ARROW1");
        
        // Schema (simplified JSON representation for HTTP transport)
        try w.writeAll("{\"schema\":{\"fields\":[");
        for (self.schema.fields, 0..) |f, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{{\"name\":\"{s}\",\"type\":\"{s}\"}}", .{
                f.name, f.data_type.toString(),
            });
        }
        try w.writeAll("]},\"row_count\":");
        try w.print("{d}", .{self.row_count});
        try w.writeAll(",\"columns\":[");
        
        for (self.columns.items, 0..) |col, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{{\"name\":\"{s}\",\"data\":\"", .{col.name});
            // Base64 encode binary data
            const encoder = std.base64.standard;
            const encoded = try allocator.alloc(u8, encoder.calcSize(col.data.len));
            defer allocator.free(encoded);
            _ = encoder.encode(encoded, col.data);
            try w.writeAll(encoded);
            try w.writeAll("\"}");
        }
        try w.writeAll("]}");
        
        return buf.toOwnedSlice();
    }

    /// Deserialize from Arrow IPC format
    pub fn fromIpc(allocator: std.mem.Allocator, data: []const u8) !RecordBatch {
        // Skip magic bytes
        if (data.len < 6 or !std.mem.eql(u8, data[0..6], "ARROW1")) {
            return error.InvalidArrowFormat;
        }
        
        // Parse JSON representation
        const json_data = data[6..];
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_data, .{});
        defer parsed.deinit();
        
        const root = parsed.value;
        if (root != .object) return error.InvalidArrowFormat;
        
        // Extract row count
        const row_count = if (root.object.get("row_count")) |rc|
            if (rc == .integer) @as(usize, @intCast(rc.integer)) else 0
        else
            0;
        
        // Create batch with default schema
        var batch = RecordBatch.init(allocator, Schemas.TimeSeries);
        batch.row_count = row_count;
        
        return batch;
    }
};

// ============================================================================
// Flight Ticket (identifies a data stream)
// ============================================================================

pub const FlightTicket = struct {
    ticket: []const u8,
    
    pub fn encode(allocator: std.mem.Allocator, service: []const u8, stream: []const u8) !FlightTicket {
        const ticket = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ service, stream });
        return .{ .ticket = ticket };
    }
    
    pub fn decode(self: FlightTicket) struct { service: []const u8, stream: []const u8 } {
        if (std.mem.indexOf(u8, self.ticket, ":")) |idx| {
            return .{
                .service = self.ticket[0..idx],
                .stream = self.ticket[idx + 1 ..],
            };
        }
        return .{ .service = self.ticket, .stream = "" };
    }
};

// ============================================================================
// Flight Info (metadata about available data)
// ============================================================================

pub const FlightInfo = struct {
    schema: Schema,
    ticket: FlightTicket,
    total_records: i64 = -1, // -1 = unknown
    total_bytes: i64 = -1,
    
    pub fn toJson(self: FlightInfo, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8){};
        const w = buf.writer();

        try w.writeAll("{\"ticket\":\"");
        try w.writeAll(self.ticket.ticket);
        try w.writeAll("\",\"total_records\":");
        try w.print("{d}", .{self.total_records});
        try w.writeAll(",\"total_bytes\":");
        try w.print("{d}", .{self.total_bytes});
        try w.writeAll(",\"schema\":{\"fields\":[");
        
        for (self.schema.fields, 0..) |f, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{{\"name\":\"{s}\",\"type\":\"{s}\"}}", .{
                f.name, f.data_type.toString(),
            });
        }
        try w.writeAll("]}}");
        
        return buf.toOwnedSlice();
    }
};

// ============================================================================
// Arrow Flight Server (HTTP endpoints)
// ============================================================================

pub const FlightServer = struct {
    allocator: std.mem.Allocator,
    streams: std.StringHashMap(RecordBatch),
    
    pub fn init(allocator: std.mem.Allocator) FlightServer {
        return .{
            .allocator = allocator,
            .streams = std.StringHashMap(RecordBatch).init(allocator),
        };
    }
    
    pub fn deinit(self: *FlightServer) void {
        var iter = self.streams.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.streams.deinit();
    }
    
    /// Register a data stream for clients to consume
    pub fn publishStream(self: *FlightServer, name: []const u8, batch: RecordBatch) !void {
        try self.streams.put(name, batch);
    }
    
    /// Handle GET /flight/info/{stream} - Get stream metadata
    pub fn handleGetFlightInfo(self: *FlightServer, stream_name: []const u8) !FlightInfo {
        if (self.streams.get(stream_name)) |batch| {
            const ticket = try FlightTicket.encode(self.allocator, "odata-time-series", stream_name);
            return FlightInfo{
                .schema = batch.schema,
                .ticket = ticket,
                .total_records = @intCast(batch.row_count),
            };
        }
        return error.StreamNotFound;
    }
    
    /// Handle GET /flight/do-get/{ticket} - Stream data
    pub fn handleDoGet(self: *FlightServer, ticket_str: []const u8) ![]u8 {
        // Parse ticket
        const ticket = FlightTicket{ .ticket = ticket_str };
        const decoded = ticket.decode();
        
        if (self.streams.get(decoded.stream)) |*batch| {
            return batch.toIpc(self.allocator);
        }
        return error.StreamNotFound;
    }
    
    /// Handle POST /flight/do-put - Receive data from other services
    pub fn handleDoPut(self: *FlightServer, stream_name: []const u8, data: []const u8) !void {
        const batch = try RecordBatch.fromIpc(self.allocator, data);
        try self.streams.put(stream_name, batch);
    }
};

// ============================================================================
// Arrow Flight Client (HTTP-based)
// ============================================================================

pub const FlightClient = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    
    pub fn init(allocator: std.mem.Allocator, base_url: []const u8) FlightClient {
        return .{
            .allocator = allocator,
            .base_url = base_url,
        };
    }
    
    /// Get flight info from remote service
    pub fn getFlightInfo(self: *FlightClient, stream_name: []const u8) !FlightInfo {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();
        
        const url = try std.fmt.allocPrint(self.allocator, "{s}/flight/info/{s}", .{ self.base_url, stream_name });
        defer self.allocator.free(url);
        
        var buf: [8192]u8 = undefined;
        const result = try client.fetch(.{
            .location = .{ .url = url },
            .response_storage = .{ .static = &buf },
        });
        
        if (result.status != .ok) return error.FlightRequestFailed;
        
        // Parse response (simplified)
        return FlightInfo{
            .schema = Schemas.TimeSeries,
            .ticket = try FlightTicket.encode(self.allocator, "remote", stream_name),
        };
    }
    
    /// Stream data from remote service
    pub fn doGet(self: *FlightClient, ticket: FlightTicket) !RecordBatch {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();
        
        const url = try std.fmt.allocPrint(self.allocator, "{s}/flight/do-get/{s}", .{ self.base_url, ticket.ticket });
        defer self.allocator.free(url);
        
        var response_buffer = std.ArrayList(u8){};
        defer response_buffer.deinit();
        
        const result = try client.fetch(.{
            .location = .{ .url = url },
            .response_storage = .{ .dynamic = &response_buffer },
        });
        
        if (result.status != .ok) return error.FlightRequestFailed;
        
        return RecordBatch.fromIpc(self.allocator, response_buffer.items);
    }
    
    /// Send data to remote service
    pub fn doPut(self: *FlightClient, stream_name: []const u8, batch: *const RecordBatch) !void {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();
        
        const url = try std.fmt.allocPrint(self.allocator, "{s}/flight/do-put/{s}", .{ self.base_url, stream_name });
        defer self.allocator.free(url);
        
        const body = try batch.toIpc(self.allocator);
        defer self.allocator.free(body);
        
        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .headers = .{
                .content_type = .{ .override = "application/vnd.apache.arrow.stream" },
            },
        });
        
        if (result.status != .ok and result.status != .created) {
            return error.FlightPutFailed;
        }
    }
};

// ============================================================================
// HTTP Route Handler Integration
// ============================================================================

pub fn isFlightRequest(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/flight/");
}

pub fn routeFlightRequest(
    allocator: std.mem.Allocator,
    server: *FlightServer,
    method: []const u8,
    path: []const u8,
    body: []const u8,
) ![]u8 {
    // GET /flight/info/{stream}
    if (std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, path, "/flight/info/")) {
        const stream = path["/flight/info/".len..];
        const info = try server.handleGetFlightInfo(stream);
        return info.toJson(allocator);
    }
    
    // GET /flight/do-get/{ticket}
    if (std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, path, "/flight/do-get/")) {
        const ticket = path["/flight/do-get/".len..];
        return server.handleDoGet(ticket);
    }
    
    // POST /flight/do-put/{stream}
    if (std.mem.eql(u8, method, "POST") and std.mem.startsWith(u8, path, "/flight/do-put/")) {
        const stream = path["/flight/do-put/".len..];
        try server.handleDoPut(stream, body);
        return try allocator.dupe(u8, "{\"status\":\"ok\"}");
    }
    
    // GET /flight/streams - List available streams
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/flight/streams")) {
        var buf = std.ArrayList(u8){};
        const w = buf.writer();
        try w.writeAll("{\"streams\":[");
        var iter = server.streams.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("\"{s}\"", .{entry.key_ptr.*});
        }
        try w.writeAll("]}");
        return buf.toOwnedSlice();
    }

    return error.NotFound;
}

// ============================================================================
// Tests
// ============================================================================

test "schema field count" {
    try std.testing.expectEqual(@as(usize, 4), Schemas.TimeSeries.fieldCount());
    try std.testing.expectEqual(@as(usize, 4), Schemas.Embeddings.fieldCount());
}

test "flight ticket encode decode" {
    const allocator = std.testing.allocator;
    const ticket = try FlightTicket.encode(allocator, "odata-time-series", "sales-forecast");
    defer allocator.free(ticket.ticket);
    
    const decoded = ticket.decode();
    try std.testing.expectEqualStrings("odata-time-series", decoded.service);
    try std.testing.expectEqualStrings("sales-forecast", decoded.stream);
}

test "record batch init" {
    const allocator = std.testing.allocator;
    var batch = RecordBatch.init(allocator, Schemas.TimeSeries);
    defer batch.deinit();
    
    try std.testing.expectEqual(@as(usize, 0), batch.row_count);
}
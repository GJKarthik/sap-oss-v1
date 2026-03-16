const std = @import("std");
const posix = std.posix;

// ============================================================================
// Deductive Database Client — HTTP client for neo4j-be-po-deductive-db
//
// Provides:
//   - Graph node/relationship CRUD
//   - Mangle Datalog queries (assert, retract, query, infer)
//   - Cypher passthrough
//   - Schema publishing (PAL results, HANA schema as graph nodes)
// ============================================================================

pub const DeductiveClient = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,

    pub fn init(allocator: std.mem.Allocator, url: []const u8) DeductiveClient {
        var host: []const u8 = "localhost";
        var port: u16 = 8080;

        var rest = url;
        if (std.mem.startsWith(u8, rest, "http://")) {
            rest = rest["http://".len..];
        } else if (std.mem.startsWith(u8, rest, "https://")) {
            rest = rest["https://".len..];
            port = 443;
        }

        if (std.mem.indexOf(u8, rest, ":")) |colon| {
            host = rest[0..colon];
            port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch port;
        } else {
            host = rest;
        }

        return .{ .allocator = allocator, .host = host, .port = port };
    }

    pub fn isConfigured(self: *const DeductiveClient) bool {
        return self.host.len > 0 and !std.mem.eql(u8, self.host, "localhost");
    }

    // ========================================================================
    // Graph CRUD
    // ========================================================================

    /// Create a node: POST /v1/graph/nodes
    pub fn createNode(self: *DeductiveClient, label: []const u8, properties_json: []const u8) ![]const u8 {
        var body: std.ArrayList(u8) = .{};
        const w = body.writer(self.allocator);
        try w.writeAll("{\"label\":");
        try writeJsonStr(w, label);
        try w.writeAll(",\"properties\":");
        try w.writeAll(properties_json);
        try w.writeByte('}');
        const req_body = try body.toOwnedSlice(self.allocator);
        defer self.allocator.free(req_body);
        return self.post("/v1/graph/nodes", req_body);
    }

    /// Create a relationship: POST /v1/graph/relationships
    pub fn createRelationship(self: *DeductiveClient, from_id: []const u8, to_id: []const u8, rel_type: []const u8, properties_json: []const u8) ![]const u8 {
        var body: std.ArrayList(u8) = .{};
        const w = body.writer(self.allocator);
        try w.writeAll("{\"from_id\":");
        try writeJsonStr(w, from_id);
        try w.writeAll(",\"to_id\":");
        try writeJsonStr(w, to_id);
        try w.writeAll(",\"type\":");
        try writeJsonStr(w, rel_type);
        try w.writeAll(",\"properties\":");
        try w.writeAll(properties_json);
        try w.writeByte('}');
        const req_body = try body.toOwnedSlice(self.allocator);
        defer self.allocator.free(req_body);
        return self.post("/v1/graph/relationships", req_body);
    }

    // ========================================================================
    // Mangle Datalog
    // ========================================================================

    /// Assert a fact: POST /v1/mangle {"assert": {"predicate": ..., "args": [...]}}
    pub fn assertFact(self: *DeductiveClient, predicate: []const u8, args: []const []const u8) ![]const u8 {
        var body: std.ArrayList(u8) = .{};
        const w = body.writer(self.allocator);
        try w.writeAll("{\"assert\":{\"predicate\":");
        try writeJsonStr(w, predicate);
        try w.writeAll(",\"args\":[");
        for (args, 0..) |arg, i| {
            if (i > 0) try w.writeByte(',');
            try writeJsonStr(w, arg);
        }
        try w.writeAll("]}}");
        const req_body = try body.toOwnedSlice(self.allocator);
        defer self.allocator.free(req_body);
        return self.post("/v1/mangle", req_body);
    }

    /// Query facts: POST /v1/mangle {"query": {"predicate": ..., "pattern": [...]}}
    pub fn queryFacts(self: *DeductiveClient, predicate: []const u8, pattern: []const []const u8) ![]const u8 {
        var body: std.ArrayList(u8) = .{};
        const w = body.writer(self.allocator);
        try w.writeAll("{\"query\":{\"predicate\":");
        try writeJsonStr(w, predicate);
        try w.writeAll(",\"pattern\":[");
        for (pattern, 0..) |p, i| {
            if (i > 0) try w.writeByte(',');
            try writeJsonStr(w, p);
        }
        try w.writeAll("]}}");
        const req_body = try body.toOwnedSlice(self.allocator);
        defer self.allocator.free(req_body);
        return self.post("/v1/mangle", req_body);
    }

    /// Run inference: POST /v1/mangle {"infer": "forward"|"backward", ...}
    pub fn infer(self: *DeductiveClient, mode: []const u8, predicate: ?[]const u8, args: ?[]const []const u8) ![]const u8 {
        var body: std.ArrayList(u8) = .{};
        const w = body.writer(self.allocator);
        try w.writeAll("{\"infer\":");
        try writeJsonStr(w, mode);
        if (predicate) |pred| {
            try w.writeAll(",\"predicate\":");
            try writeJsonStr(w, pred);
        }
        if (args) |a| {
            try w.writeAll(",\"args\":[");
            for (a, 0..) |arg, i| {
                if (i > 0) try w.writeByte(',');
                try writeJsonStr(w, arg);
            }
            try w.writeByte(']');
        }
        try w.writeByte('}');
        const req_body = try body.toOwnedSlice(self.allocator);
        defer self.allocator.free(req_body);
        return self.post("/v1/mangle", req_body);
    }

    // ========================================================================
    // Chat Completions (NL query via OpenAI-compatible endpoint)
    // ========================================================================

    /// Send a natural language query: POST /v1/chat/completions
    pub fn chatQuery(self: *DeductiveClient, message: []const u8) ![]const u8 {
        var body: std.ArrayList(u8) = .{};
        const w = body.writer(self.allocator);
        try w.writeAll("{\"model\":\"ainuc-deductive-v1\",\"messages\":[{\"role\":\"user\",\"content\":");
        try writeJsonStr(w, message);
        try w.writeAll("}]}");
        const req_body = try body.toOwnedSlice(self.allocator);
        defer self.allocator.free(req_body);
        return self.post("/v1/chat/completions", req_body);
    }

    /// Execute raw Cypher: POST /v1/cypher
    pub fn executeCypher(self: *DeductiveClient, cypher: []const u8) ![]const u8 {
        return self.post("/v1/cypher", cypher);
    }

    // ========================================================================
    // OData Proxy — fetch data from SAP OData services via deductive-db
    // ========================================================================

    /// Fetch OData entity set data via chat completions interface
    pub fn odataFetch(self: *DeductiveClient, service_url: []const u8, entity_set: []const u8, top: usize) ![]const u8 {
        var body: std.ArrayList(u8) = .{};
        const w = body.writer(self.allocator);
        try w.writeAll("{\"model\":\"ainuc-deductive-v1\",\"messages\":[{\"role\":\"user\",\"content\":");
        var msg: std.ArrayList(u8) = .{};
        const mw = msg.writer(self.allocator);
        try mw.print("fetch odata {s}/{s}?$top={d}", .{ service_url, entity_set, top });
        const msg_str = try msg.toOwnedSlice(self.allocator);
        defer self.allocator.free(msg_str);
        try writeJsonStr(w, msg_str);
        try w.writeAll("}]}");
        const req_body = try body.toOwnedSlice(self.allocator);
        defer self.allocator.free(req_body);
        return self.post("/v1/chat/completions", req_body);
    }

    // ========================================================================
    // HTTP Transport
    // ========================================================================

    fn post(self: *DeductiveClient, path: []const u8, req_body: []const u8) ![]const u8 {
        var req: std.ArrayList(u8) = .{};
        const rw = req.writer(self.allocator);
        try rw.print("POST {s} HTTP/1.1\r\n", .{path});
        try rw.print("Host: {s}:{d}\r\n", .{ self.host, self.port });
        try rw.writeAll("Content-Type: application/json\r\n");
        try rw.print("Content-Length: {d}\r\n", .{req_body.len});
        try rw.writeAll("Connection: close\r\n\r\n");
        try rw.writeAll(req_body);
        const req_data = try req.toOwnedSlice(self.allocator);
        defer self.allocator.free(req_data);

        const addr = std.net.Address.parseIp4(self.host, self.port) catch blk: {
            if (std.mem.eql(u8, self.host, "localhost")) {
                break :blk try std.net.Address.parseIp4("127.0.0.1", self.port);
            }

            const addrs = std.net.getAddressList(self.allocator, self.host, self.port) catch return error.UnableToResolve;
            defer addrs.deinit();
            if (addrs.addrs.len == 0) return error.UnableToResolve;
            break :blk addrs.addrs[0];
        };

        const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        defer posix.close(sock);
        try posix.connect(sock, &addr.any, addr.getOsSockLen());
        _ = try posix.write(sock, req_data);

        var response: std.ArrayList(u8) = .{};
        var read_buf: [8192]u8 = undefined;
        while (true) {
            const n = posix.read(sock, &read_buf) catch break;
            if (n == 0) break;
            try response.appendSlice(self.allocator, read_buf[0..n]);
        }

        const full = try response.toOwnedSlice(self.allocator);
        if (std.mem.indexOf(u8, full, "\r\n\r\n")) |hdr_end| {
            const result = try self.allocator.dupe(u8, full[hdr_end + 4 ..]);
            self.allocator.free(full);
            return result;
        }
        return full;
    }
};

fn writeJsonStr(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

// ============================================================================
// Tests
// ============================================================================

test "deductive client parse url" {
    const allocator = std.testing.allocator;
    const client = DeductiveClient.init(allocator, "http://deductive-db:8080");
    try std.testing.expectEqualStrings("deductive-db", client.host);
    try std.testing.expectEqual(@as(u16, 8080), client.port);
}

test "deductive client localhost not configured" {
    const allocator = std.testing.allocator;
    const client = DeductiveClient.init(allocator, "http://localhost:8080");
    try std.testing.expect(!client.isConfigured());
}

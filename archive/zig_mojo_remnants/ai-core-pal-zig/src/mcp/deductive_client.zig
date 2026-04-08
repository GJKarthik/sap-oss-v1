const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ============================================================================
// Deductive Database Client — HTTP proxy to Kuzu/HippoCPP backend
// ============================================================================

pub const DeductiveClient = struct {
    allocator: Allocator,
    host: []const u8,
    port: u16,

    pub fn init(allocator: Allocator, url: []const u8) DeductiveClient {
        // Simple URL parser
        var host: []const u8 = "localhost";
        var port: u16 = 8080;
        var rest = url;
        if (mem.startsWith(u8, rest, "http://")) {
            rest = rest[7..];
        } else if (mem.startsWith(u8, rest, "https://")) {
            rest = rest[8..];
            port = 443;
        }

        if (mem.indexOf(u8, rest, ":")) |colon| {
            host = rest[0..colon];
            port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch port;
        } else {
            host = rest;
        }

        return .{
            .allocator = allocator,
            .host = host,
            .port = port,
        };
    }

    pub fn isConfigured(self: *const DeductiveClient) bool {
        return self.host.len > 0 and !mem.eql(u8, self.host, "localhost");
    }

    /// Create a new node in the graph
    pub fn createNode(self: *DeductiveClient, label: []const u8, props_json: []const u8) ![]const u8 {
        var body = std.ArrayList(u8).init(self.allocator);
        defer body.deinit();
        const w = body.writer();
        try w.print("{{\"label\":\"{s}\",\"properties\":{s}}}", .{ label, props_json });
        
        const req_data = try body.toOwnedSlice();
        defer self.allocator.free(req_data);

        return self.post("/v1/graph/node", req_data);
    }

    /// Execute a Cypher/Datalog query
    pub fn chatQuery(self: *DeductiveClient, query: []const u8) ![]const u8 {
        var body = std.ArrayList(u8).init(self.allocator);
        defer body.deinit();
        const w = body.writer();
        try w.writeAll("{\"query\":");
        try writeJsonStr(w, query);
        try w.writeAll("}");

        const req_data = try body.toOwnedSlice();
        defer self.allocator.free(req_data);

        return self.post("/v1/graph/query", req_data);
    }

    /// Run inference across the graph
    pub fn infer(self: *DeductiveClient, direction: []const u8, predicate: []const u8, args: []const []const u8) ![]const u8 {
        var body = std.ArrayList(u8).init(self.allocator);
        defer body.deinit();
        const w = body.writer();
        try w.print("{{\"direction\":\"{s}\",\"predicate\":\"{s}\",\"args\":[", .{ direction, predicate });
        for (args, 0..) |arg, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("\"{s}\"", .{arg});
        }
        try w.writeAll("]}");

        const req_data = try body.toOwnedSlice();
        defer self.allocator.free(req_data);

        return self.post("/v1/graph/infer", req_data);
    }

    /// Query raw facts from the deductive database
    pub fn queryFacts(self: *DeductiveClient, predicate: []const u8, args: []const []const u8) ![]const u8 {
        var body = std.ArrayList(u8).init(self.allocator);
        defer body.deinit();
        const w = body.writer();
        try w.print("{{\"predicate\":\"{s}\",\"args\":[", .{predicate});
        for (args, 0..) |arg, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("\"{s}\"", .{arg});
        }
        try w.writeAll("]}");

        const req_data = try body.toOwnedSlice();
        defer self.allocator.free(req_data);

        return self.post("/v1/graph/facts", req_data);
    }

    /// Fetch data via OData with deductive graph resolution
    pub fn odataFetch(self: *DeductiveClient, service_url: []const u8, entity_set: []const u8, top: usize) ![]const u8 {
        var body = std.ArrayList(u8).init(self.allocator);
        defer body.deinit();
        const w = body.writer();
        try w.print("{{\"service_url\":\"{s}\",\"entity_set\":\"{s}\",\"top\":{d}}}", .{ service_url, entity_set, top });

        const req_data = try body.toOwnedSlice();
        defer self.allocator.free(req_data);

        return self.post("/v1/graph/odata", req_data);
    }

    fn post(self: *DeductiveClient, path: []const u8, body: []const u8) ![]const u8 {
        const addr = std.net.Address.parseIp4(self.host, self.port) catch return error.UnableToResolve;
        const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        defer std.posix.close(sock);
        try std.posix.connect(sock, &addr.any, addr.getOsSockLen());

        var req = std.ArrayList(u8).init(self.allocator);
        defer req.deinit();
        const rw = req.writer();
        try rw.print("POST {s} HTTP/1.1\r\n", .{path});
        try rw.print("Host: {s}\r\n", .{self.host});
        try rw.writeAll("Content-Type: application/json\r\n");
        try rw.print("Content-Length: {d}\r\n", .{body.len});
        try rw.writeAll("Connection: close\r\n\r\n");
        try rw.writeAll(body);

        _ = try std.posix.write(sock, req.items);

        var response = std.ArrayList(u8).init(self.allocator);
        defer response.deinit();
        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(sock, &read_buf) catch break;
            if (n == 0) break;
            try response.appendSlice(read_buf[0..n]);
        }

        const sep = mem.indexOf(u8, response.items, "\r\n\r\n") orelse 0;
        if (sep > 0) {
            return try self.allocator.dupe(u8, response.items[sep + 4 ..]);
        }
        return try response.toOwnedSlice();
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

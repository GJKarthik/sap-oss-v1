const std = @import("std");

pub const Method = enum {
    GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS, CONNECT, TRACE,
    UNKNOWN,

    pub fn parse(s: []const u8) Method {
        if (std.mem.eql(u8, s, "GET")) return .GET;
        if (std.mem.eql(u8, s, "POST")) return .POST;
        if (std.mem.eql(u8, s, "PUT")) return .PUT;
        if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, s, "PATCH")) return .PATCH;
        if (std.mem.eql(u8, s, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, s, "OPTIONS")) return .OPTIONS;
        return .UNKNOWN;
    }
};

pub const Request = struct {
    method: Method,
    path: []const u8,
    version: []const u8,
    headers: std.StringHashMapUnmanaged([]const u8),
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn parse(allocator: std.mem.Allocator, buffer: []const u8) !Request {
        var line_it = std.mem.splitSequence(u8, buffer, "
");
        const first_line = line_it.next() orelse return error.BadRequest;
        
        var part_it = std.mem.splitScalar(u8, first_line, ' ');
        const method_str = part_it.next() orelse return error.BadRequest;
        const path = part_it.next() orelse return error.BadRequest;
        const version = part_it.next() orelse return error.BadRequest;

        var headers = std.StringHashMapUnmanaged([]const u8){};
        while (line_it.next()) |line| {
            if (line.len == 0) break;
            const colon_idx = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const key = std.mem.trim(u8, line[0..colon_idx], " ");
            const value = std.mem.trim(u8, line[colon_idx + 1 ..], " ");
            try headers.put(allocator, key, value);
        }

        const body = line_it.rest();

        return .{
            .method = Method.parse(method_str),
            .path = path,
            .version = version,
            .headers = headers,
            .body = body,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Request) void {
        var headers = self.headers;
        headers.deinit(self.allocator);
    }
};

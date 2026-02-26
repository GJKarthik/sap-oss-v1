const std = @import("std");

pub const Status = enum(u16) {
    OK = 200,
    Created = 201,
    Accepted = 202,
    NoContent = 204,
    BadRequest = 400,
    Unauthorized = 401,
    Forbidden = 403,
    NotFound = 404,
    InternalServerError = 500,
    NotImplemented = 501,
    ServiceUnavailable = 503,

    pub fn text(self: Status) []const u8 {
        return switch (self) {
            .OK => "OK",
            .Created => "Created",
            .BadRequest => "Bad Request",
            .NotFound => "Not Found",
            .InternalServerError => "Internal Server Error",
            else => "Unknown",
        };
    }
};

pub const Response = struct {
    status: Status = .OK,
    headers: std.StringHashMapUnmanaged([]const u8) = .{},
    body: []const u8 = "",
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Response {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Response) void {
        var headers = self.headers;
        headers.deinit(self.allocator);
    }

    pub fn write(self: Response, writer: anytype) !void {
        try writer.print("HTTP/1.1 {d} {s}
", .{ @intFromEnum(self.status), self.status.text() });
        var it = self.headers.iterator();
        while (it.next()) |entry| {
            try writer.print("{s}: {s}
", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        try writer.print("Content-Length: {d}
", .{ self.body.len });
        try writer.writeAll("Connection: close

");
        try writer.writeAll(self.body);
    }
};

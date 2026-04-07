const std = @import("std");
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const Allocator = mem.Allocator;

pub const Response = struct {
    allocator: Allocator,
    status: u16,
    body: []u8,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
    }

    pub fn isSuccess(self: Response) bool {
        return self.status >= 200 and self.status < 300;
    }
};

pub fn buildJsonRequest(
    allocator: Allocator,
    method: []const u8,
    host: []const u8,
    path: []const u8,
    body: ?[]const u8,
    auth_header: ?[]const u8,
) ![]u8 {
    var request = std.ArrayListUnmanaged(u8){};
    errdefer request.deinit(allocator);
    var writer = request.writer(allocator);

    try writer.print("{s} {s} HTTP/1.1\r\n", .{ method, path });
    try writer.print("Host: {s}\r\n", .{host});
    try writer.writeAll("Accept: application/json\r\n");
    if (body != null) {
        try writer.writeAll("Content-Type: application/json\r\n");
    }
    if (auth_header) |auth| {
        try writer.print("Authorization: {s}\r\n", .{auth});
    }
    if (body) |body_bytes| {
        try writer.print("Content-Length: {d}\r\n", .{body_bytes.len});
    }
    try writer.writeAll("Connection: close\r\n");
    try writer.writeAll("\r\n");
    if (body) |body_bytes| {
        try writer.writeAll(body_bytes);
    }

    return request.toOwnedSlice(allocator);
}

pub fn executeRequest(
    allocator: Allocator,
    host: []const u8,
    port: u16,
    request: []const u8,
) !Response {
    const address = try resolveAddress(host, port);
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(sock);

    try posix.connect(sock, &address.any, address.getOsSockLen());
    try writeAllSocket(sock, request);

    var response = std.ArrayListUnmanaged(u8){};
    defer response.deinit(allocator);

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try posix.read(sock, &buf);
        if (n == 0) break;
        try response.appendSlice(allocator, buf[0..n]);
    }

    return try parseBufferedResponse(allocator, response.items);
}

pub fn streamRequest(
    host: []const u8,
    port: u16,
    request: []const u8,
    downstream: net.Stream,
) !void {
    const address = try resolveAddress(host, port);
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(sock);

    try posix.connect(sock, &address.any, address.getOsSockLen());
    try writeAllSocket(sock, request);

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try posix.read(sock, &buf);
        if (n == 0) break;
        try downstream.writeAll(buf[0..n]);
    }
}

pub fn parseBufferedResponse(allocator: Allocator, raw: []const u8) !Response {
    const header_end = mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.InvalidHttpResponse;
    const header_blob = raw[0..header_end];
    const body_blob = raw[header_end + 4 ..];

    const status_line_end = mem.indexOf(u8, header_blob, "\r\n") orelse header_blob.len;
    const status = try parseStatusCode(header_blob[0..status_line_end]);
    const transfer_encoding = findHeaderValue(header_blob, "Transfer-Encoding");

    const body = if (transfer_encoding) |value|
        if (containsChunked(value))
            try decodeChunkedBody(allocator, body_blob)
        else
            try allocator.dupe(u8, body_blob)
    else
        try allocator.dupe(u8, body_blob);

    return .{
        .allocator = allocator,
        .status = status,
        .body = body,
    };
}

fn resolveAddress(host: []const u8, port: u16) !net.Address {
    return net.Address.parseIp4(host, port) catch blk: {
        if (std.mem.eql(u8, host, "localhost")) {
            break :blk try net.Address.parseIp4("127.0.0.1", port);
        }
        return error.UnableToResolve;
    };
}

fn writeAllSocket(sock: posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = try posix.write(sock, bytes[written..]);
        if (n == 0) return error.ConnectionResetByPeer;
        written += n;
    }
}

fn parseStatusCode(status_line: []const u8) !u16 {
    var parts = mem.tokenizeScalar(u8, status_line, ' ');
    _ = parts.next() orelse return error.InvalidHttpResponse;
    const status_text = parts.next() orelse return error.InvalidHttpResponse;
    return std.fmt.parseInt(u16, status_text, 10) catch error.InvalidHttpResponse;
}

fn findHeaderValue(headers_blob: []const u8, header_name: []const u8) ?[]const u8 {
    var lines = mem.splitSequence(u8, headers_blob, "\r\n");
    _ = lines.next(); // status line

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(key, header_name)) continue;
        return mem.trim(u8, line[colon + 1 ..], " \t");
    }

    return null;
}

fn containsChunked(value: []const u8) bool {
    var parts = mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        if (std.ascii.eqlIgnoreCase(mem.trim(u8, part, " \t"), "chunked")) {
            return true;
        }
    }
    return false;
}

fn decodeChunkedBody(allocator: Allocator, data: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (true) {
        const line_end_rel = mem.indexOf(u8, data[index..], "\r\n") orelse return error.InvalidChunkedEncoding;
        const size_line = mem.trim(u8, data[index .. index + line_end_rel], " \t");
        const extension_sep = mem.indexOfScalar(u8, size_line, ';') orelse size_line.len;
        const chunk_size = std.fmt.parseInt(usize, size_line[0..extension_sep], 16) catch {
            return error.InvalidChunkedEncoding;
        };
        index += line_end_rel + 2;

        if (chunk_size == 0) break;
        if (index + chunk_size > data.len) return error.InvalidChunkedEncoding;

        try out.appendSlice(allocator, data[index .. index + chunk_size]);
        index += chunk_size;

        if (index + 2 > data.len or !mem.eql(u8, data[index .. index + 2], "\r\n")) {
            return error.InvalidChunkedEncoding;
        }
        index += 2;
    }

    return out.toOwnedSlice(allocator);
}

test "parse buffered response preserves status" {
    const raw =
        "HTTP/1.1 404 Not Found\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 18\r\n\r\n" ++
        "{\"error\":\"missing\"}";

    var response = try parseBufferedResponse(std.testing.allocator, raw);
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 404), response.status);
    try std.testing.expectEqualStrings("{\"error\":\"missing\"}", response.body);
}

test "parse buffered response decodes chunked body" {
    const raw =
        "HTTP/1.1 200 OK\r\n" ++
        "Transfer-Encoding: chunked\r\n\r\n" ++
        "7\r\nMozilla\r\n" ++
        "9\r\nDeveloper\r\n" ++
        "7\r\nNetwork\r\n" ++
        "0\r\n\r\n";

    var response = try parseBufferedResponse(std.testing.allocator, raw);
    defer response.deinit();

    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("MozillaDeveloperNetwork", response.body);
}

//! LLM Backend Client
//!
//! HTTP client for communicating with local LLM backends (Rust/llama.cpp).

const std = @import("std");
const net = std.net;
const Allocator = std.mem.Allocator;
const posix = std.posix;

pub const HttpResponse = struct {
    allocator: Allocator,
    status: u16,
    body: []u8,

    pub fn deinit(self: *HttpResponse) void {
        self.allocator.free(self.body);
    }

    pub fn isSuccess(self: HttpResponse) bool {
        return self.status >= 200 and self.status < 300;
    }
};

pub const Client = struct {
    allocator: Allocator,
    base_url: []const u8,
    auth_header: ?[]const u8,

    pub fn init(allocator: Allocator, base_url: []const u8) !Client {
        return Client{
            .allocator = allocator,
            .base_url = base_url,
            .auth_header = null,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.auth_header) |h| {
            self.allocator.free(h);
        }
    }

    pub fn setApiKey(self: *Client, api_key: []const u8) !void {
        self.auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{api_key});
    }

    // ========================================================================
    // OpenAI-Compatible Endpoints
    // ========================================================================

    /// POST /v1/chat/completions
    pub fn chatCompletions(self: *Client, body: []const u8) ![]const u8 {
        return self.requireSuccess(try self.postResponse("/v1/chat/completions", body));
    }

    /// POST /v1/completions
    pub fn completions(self: *Client, body: []const u8) ![]const u8 {
        return self.requireSuccess(try self.postResponse("/v1/completions", body));
    }

    /// POST /v1/embeddings
    pub fn embeddings(self: *Client, body: []const u8) ![]const u8 {
        return self.requireSuccess(try self.postResponse("/v1/embeddings", body));
    }

    /// GET /v1/models
    pub fn models(self: *Client) ![]const u8 {
        return self.requireSuccess(try self.doGetResponse("/v1/models"));
    }

    /// GET /health
    pub fn health(self: *Client) ![]const u8 {
        return self.requireSuccess(try self.doGetResponse("/health"));
    }

    // ========================================================================
    // HTTP Methods
    // ========================================================================

    fn parseUrl(self: *Client) struct { host: []const u8, port: u16, https: bool } {
        var url = self.base_url;

        var https = false;
        if (std.mem.startsWith(u8, url, "https://")) {
            url = url[8..];
            https = true;
        } else if (std.mem.startsWith(u8, url, "http://")) {
            url = url[7..];
        }

        var port: u16 = if (https) 443 else 80;
        var host = url;

        if (std.mem.indexOf(u8, url, ":")) |colon_pos| {
            host = url[0..colon_pos];
            const port_str = url[colon_pos + 1 ..];
            port = std.fmt.parseInt(u16, port_str, 10) catch port;
        }

        return .{ .host = host, .port = port, .https = https };
    }

    fn doGetResponse(self: *Client, path: []const u8) !HttpResponse {
        const url_info = self.parseUrl();

        const request = try buildJsonRequest(
            self.allocator,
            "GET",
            url_info.host,
            path,
            null,
            self.auth_header,
        );
        defer self.allocator.free(request);

        return executeRequest(self.allocator, url_info.host, url_info.port, request);
    }

    fn postResponse(self: *Client, path: []const u8, body: []const u8) !HttpResponse {
        const url_info = self.parseUrl();

        const request = try buildJsonRequest(
            self.allocator,
            "POST",
            url_info.host,
            path,
            body,
            self.auth_header,
        );
        defer self.allocator.free(request);

        return executeRequest(self.allocator, url_info.host, url_info.port, request);
    }

    fn requireSuccess(self: *Client, response: HttpResponse) ![]const u8 {
        _ = self;
        if (!response.isSuccess()) {
            var failed = response;
            failed.deinit();
            return error.UpstreamRequestFailed;
        }
        return response.body;
    }
};

fn buildJsonRequest(
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

fn executeRequest(allocator: Allocator, host: []const u8, port: u16, request: []const u8) !HttpResponse {
    const address = resolveAddress(host, port) catch |err| return err;
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

    return parseBufferedResponse(allocator, response.items);
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

fn parseBufferedResponse(allocator: Allocator, raw: []const u8) !HttpResponse {
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.InvalidHttpResponse;
    const header_blob = raw[0..header_end];
    const body_blob = raw[header_end + 4 ..];

    const status_line_end = std.mem.indexOf(u8, header_blob, "\r\n") orelse header_blob.len;
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

fn parseStatusCode(status_line: []const u8) !u16 {
    var parts = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = parts.next() orelse return error.InvalidHttpResponse;
    const status_text = parts.next() orelse return error.InvalidHttpResponse;
    return std.fmt.parseInt(u16, status_text, 10) catch error.InvalidHttpResponse;
}

fn findHeaderValue(headers_blob: []const u8, header_name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers_blob, "\r\n");
    _ = lines.next();

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(key, header_name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }

    return null;
}

fn containsChunked(value: []const u8) bool {
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), "chunked")) {
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
        const line_end_rel = std.mem.indexOf(u8, data[index..], "\r\n") orelse return error.InvalidChunkedEncoding;
        const size_line = std.mem.trim(u8, data[index .. index + line_end_rel], " \t");
        const extension_sep = std.mem.indexOfScalar(u8, size_line, ';') orelse size_line.len;
        const chunk_size = std.fmt.parseInt(usize, size_line[0..extension_sep], 16) catch {
            return error.InvalidChunkedEncoding;
        };
        index += line_end_rel + 2;

        if (chunk_size == 0) break;
        if (index + chunk_size > data.len) return error.InvalidChunkedEncoding;

        try out.appendSlice(allocator, data[index .. index + chunk_size]);
        index += chunk_size;

        if (index + 2 > data.len or !std.mem.eql(u8, data[index .. index + 2], "\r\n")) {
            return error.InvalidChunkedEncoding;
        }
        index += 2;
    }

    return out.toOwnedSlice(allocator);
}

// ============================================================================
// Model Spec Types
// ============================================================================

pub const ModelSpec = struct {
    name: []const u8,
    template: ?[]const u8 = null,
    ctx_len: u32 = 2048,
    n_threads: ?u32 = null,
};

pub const TemplateFamily = enum {
    chatml,
    llama3,
    openchat,
    mistral,
    phi,

    pub fn stopTokens(self: TemplateFamily) []const []const u8 {
        return switch (self) {
            .chatml => &[_][]const u8{ "<|im_end|>", "<|endoftext|>" },
            .llama3 => &[_][]const u8{ "<|eot_id|>", "<|end_of_text|>" },
            .openchat => &[_][]const u8{ "<|end_of_turn|>", "</s>" },
            .mistral => &[_][]const u8{"</s>"},
            .phi => &[_][]const u8{ "<|end|>", "<|endoftext|>" },
        };
    }

    pub fn detectFromModel(name: []const u8) TemplateFamily {
        var lower_buf: [256]u8 = undefined;
        const truncated = if (name.len > lower_buf.len) name[0..lower_buf.len] else name;
        const lower = std.ascii.lowerString(lower_buf[0..truncated.len], truncated);

        if (std.mem.indexOf(u8, lower, "qwen") != null or
            std.mem.indexOf(u8, lower, "chatglm") != null)
        {
            return .chatml;
        }
        if (std.mem.indexOf(u8, lower, "llama-3") != null or
            std.mem.indexOf(u8, lower, "llama3") != null)
        {
            return .llama3;
        }
        if (std.mem.indexOf(u8, lower, "mistral") != null) {
            return .mistral;
        }
        if (std.mem.indexOf(u8, lower, "phi") != null) {
            return .phi;
        }
        return .openchat;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "parse url with port" {
    const allocator = std.testing.allocator;
    var client = try Client.init(allocator, "http://localhost:3000");
    defer client.deinit();

    const info = client.parseUrl();
    try std.testing.expectEqualStrings("localhost", info.host);
    try std.testing.expectEqual(@as(u16, 3000), info.port);
    try std.testing.expectEqual(false, info.https);
}

test "parse url without port" {
    const allocator = std.testing.allocator;
    var client = try Client.init(allocator, "http://localhost");
    defer client.deinit();

    const info = client.parseUrl();
    try std.testing.expectEqualStrings("localhost", info.host);
    try std.testing.expectEqual(@as(u16, 80), info.port);
}

test "template family detection" {
    try std.testing.expectEqual(TemplateFamily.chatml, TemplateFamily.detectFromModel("qwen2-7b"));
    try std.testing.expectEqual(TemplateFamily.llama3, TemplateFamily.detectFromModel("llama-3-8b"));
    try std.testing.expectEqual(TemplateFamily.mistral, TemplateFamily.detectFromModel("mistral-7b"));
}

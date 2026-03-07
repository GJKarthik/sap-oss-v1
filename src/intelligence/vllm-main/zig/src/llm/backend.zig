//! LLM Backend Client
//!
//! HTTP client for communicating with local LLM backends (Rust/llama.cpp).

const std = @import("std");
const net = std.net;
const Allocator = std.mem.Allocator;
const posix = std.posix;

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
        return self.post("/v1/chat/completions", body);
    }

    /// POST /v1/completions
    pub fn completions(self: *Client, body: []const u8) ![]const u8 {
        return self.post("/v1/completions", body);
    }

    /// POST /v1/embeddings
    pub fn embeddings(self: *Client, body: []const u8) ![]const u8 {
        return self.post("/v1/embeddings", body);
    }

    /// GET /v1/models
    pub fn models(self: *Client) ![]const u8 {
        return self.doGet("/v1/models");
    }

    /// GET /health
    pub fn health(self: *Client) ![]const u8 {
        return self.doGet("/health");
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

    fn doGet(self: *Client, path: []const u8) ![]const u8 {
        const url_info = self.parseUrl();
        
        var request = std.ArrayListUnmanaged(u8){};
        var writer = request.writer(self.allocator);
        
        try writer.print("GET {s} HTTP/1.1\r\n", .{path});
        try writer.print("Host: {s}\r\n", .{url_info.host});
        try writer.writeAll("Accept: application/json\r\n");
        if (self.auth_header) |auth| {
            try writer.print("Authorization: {s}\r\n", .{auth});
        }
        try writer.writeAll("Connection: close\r\n");
        try writer.writeAll("\r\n");
        
        defer request.deinit(self.allocator);
        
        return self.sendRequest(url_info.host, url_info.port, request.items);
    }

    fn post(self: *Client, path: []const u8, body: []const u8) ![]const u8 {
        const url_info = self.parseUrl();
        
        var request = std.ArrayListUnmanaged(u8){};
        var writer = request.writer(self.allocator);
        
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
        
        defer request.deinit(self.allocator);
        
        return self.sendRequest(url_info.host, url_info.port, request.items);
    }

    fn sendRequest(self: *Client, host: []const u8, port: u16, request: []const u8) ![]const u8 {
        const address = net.Address.parseIp4(host, port) catch blk: {
            // Try localhost for common local addresses
            if (std.mem.eql(u8, host, "localhost")) {
                break :blk try net.Address.parseIp4("127.0.0.1", port);
            }
            return error.UnableToResolve;
        };
        
        const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        defer posix.close(sock);
        
        try posix.connect(sock, &address.any, address.getOsSockLen());
        
        _ = try posix.write(sock, request);
        
        var response = std.ArrayListUnmanaged(u8){};
        var buf: [8192]u8 = undefined;
        
        while (true) {
            const n = posix.read(sock, &buf) catch break;
            if (n == 0) break;
            try response.appendSlice(self.allocator, buf[0..n]);
        }
        
        // Extract body (after \r\n\r\n)
        const body_start = std.mem.indexOf(u8, response.items, "\r\n\r\n") orelse 0;
        if (body_start > 0) {
            const body = response.items[body_start + 4 ..];
            const result = try self.allocator.dupe(u8, body);
            response.deinit(self.allocator);
            return result;
        }
        
        return response.toOwnedSlice(self.allocator);
    }
};

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
            std.mem.indexOf(u8, lower, "chatglm") != null) {
            return .chatml;
        }
        if (std.mem.indexOf(u8, lower, "llama-3") != null or
            std.mem.indexOf(u8, lower, "llama3") != null) {
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

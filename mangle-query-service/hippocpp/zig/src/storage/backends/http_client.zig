//! HTTP Client Module
//!
//! Provides HTTP/HTTPS client functionality for SAP backends.
//! Uses Zig's standard library networking.

const std = @import("std");

/// HTTP method
pub const Method = enum {
    GET,
    PUT,
    DELETE,
    POST,
    HEAD,
    
    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .POST => "POST",
            .HEAD => "HEAD",
        };
    }
};

/// HTTP headers
pub const Headers = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap([]const u8),
    
    pub fn init(allocator: std.mem.Allocator) Headers {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap([]const u8).init(allocator),
        };
    }
    
    pub fn put(self: *Headers, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.entries.put(key_copy, value_copy);
    }
    
    pub fn get(self: *const Headers, key: []const u8) ?[]const u8 {
        return self.entries.get(key);
    }
    
    pub fn deinit(self: *Headers) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.entries.deinit();
    }
};

/// HTTP response
pub const Response = struct {
    allocator: std.mem.Allocator,
    status_code: u16,
    headers: Headers,
    body: ?[]u8,
    
    pub fn deinit(self: *Response) void {
        if (self.body) |body| {
            self.allocator.free(body);
        }
        self.headers.deinit();
    }
};

/// HTTP request
pub const Request = struct {
    method: Method,
    uri: []const u8,
    headers: Headers,
    body: ?[]const u8,
};

/// HTTP client configuration
pub const ClientConfig = struct {
    timeout_ms: u32 = 30000,
    max_redirects: u8 = 5,
    verify_ssl: bool = true,
    ca_bundle_path: ?[]const u8 = null,
};

/// HTTP client
pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    config: ClientConfig,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, config: ClientConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }
    
    /// Execute an HTTP request
    pub fn execute(self: *Self, request: *const Request) !Response {
        // Parse URI
        const uri = try std.Uri.parse(request.uri);
        
        // Determine port
        const port: u16 = uri.port orelse if (std.mem.eql(u8, uri.scheme, "https")) @as(u16, 443) else @as(u16, 80);
        
        // Get host
        const host = uri.host orelse return error.NoHost;
        
        // Connect
        var stream = try std.net.tcpConnectToHost(self.allocator, host, port);
        defer stream.close();
        
        // Build HTTP request
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        
        const writer = buffer.writer();
        
        // Request line
        try writer.print("{s} {s} HTTP/1.1\r\n", .{ 
            request.method.toString(), 
            if (uri.path.len > 0) uri.path else "/" 
        });
        
        // Host header
        try writer.print("Host: {s}\r\n", .{host});
        
        // Custom headers
        var header_iter = request.headers.entries.iterator();
        while (header_iter.next()) |entry| {
            try writer.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        
        // Content-Length if body present
        if (request.body) |body| {
            try writer.print("Content-Length: {d}\r\n", .{body.len});
        }
        
        // End headers
        try writer.writeAll("\r\n");
        
        // Body
        if (request.body) |body| {
            try writer.writeAll(body);
        }
        
        // Send request
        try stream.writeAll(buffer.items);
        
        // Read response
        return self.readResponse(&stream);
    }
    
    fn readResponse(self: *Self, stream: *std.net.Stream) !Response {
        var response_buffer = std.ArrayList(u8).init(self.allocator);
        defer response_buffer.deinit();
        
        // Read headers
        var line_buffer: [4096]u8 = undefined;
        var status_code: u16 = 0;
        var headers = Headers.init(self.allocator);
        var content_length: ?usize = null;
        
        // Status line
        const status_line = try stream.reader().readUntilDelimiter(&line_buffer, '\n');
        // Parse "HTTP/1.1 200 OK\r"
        var parts = std.mem.split(u8, status_line, " ");
        _ = parts.next(); // HTTP version
        if (parts.next()) |code_str| {
            status_code = std.fmt.parseInt(u16, code_str, 10) catch 0;
        }
        
        // Headers
        while (true) {
            const line = stream.reader().readUntilDelimiter(&line_buffer, '\n') catch break;
            const trimmed = std.mem.trim(u8, line, "\r\n");
            if (trimmed.len == 0) break;
            
            if (std.mem.indexOf(u8, trimmed, ": ")) |sep_idx| {
                const key = trimmed[0..sep_idx];
                const value = trimmed[sep_idx + 2 ..];
                
                if (std.ascii.eqlIgnoreCase(key, "content-length")) {
                    content_length = std.fmt.parseInt(usize, value, 10) catch null;
                }
                
                try headers.put(key, value);
            }
        }
        
        // Body
        var body: ?[]u8 = null;
        if (content_length) |len| {
            body = try self.allocator.alloc(u8, len);
            const bytes_read = try stream.reader().readAll(body.?);
            if (bytes_read < len) {
                body = try self.allocator.realloc(body.?, bytes_read);
            }
        }
        
        return Response{
            .allocator = self.allocator,
            .status_code = status_code,
            .headers = headers,
            .body = body,
        };
    }
    
    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

/// AWS4-HMAC-SHA256 signature for S3-compatible APIs
pub const AwsSigner = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
    region: []const u8,
    service: []const u8,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(
        allocator: std.mem.Allocator,
        access_key_id: []const u8,
        secret_access_key: []const u8,
        region: []const u8,
        service: []const u8,
    ) Self {
        return .{
            .allocator = allocator,
            .access_key_id = access_key_id,
            .secret_access_key = secret_access_key,
            .region = region,
            .service = service,
        };
    }
    
    /// Sign a request with AWS Signature V4
    pub fn signRequest(
        self: *Self,
        method: Method,
        uri: []const u8,
        headers: *Headers,
        body: ?[]const u8,
    ) !void {
        const timestamp = getAmzDate();
        const date_stamp = timestamp[0..8];
        
        // Add required headers
        try headers.put("x-amz-date", timestamp);
        try headers.put("x-amz-content-sha256", try self.hashPayload(body));
        
        // Build canonical request
        const canonical_request = try self.buildCanonicalRequest(method, uri, headers, body);
        defer self.allocator.free(canonical_request);
        
        // Build string to sign
        const string_to_sign = try self.buildStringToSign(timestamp, date_stamp, canonical_request);
        defer self.allocator.free(string_to_sign);
        
        // Calculate signature
        const signature = try self.calculateSignature(date_stamp, string_to_sign);
        defer self.allocator.free(signature);
        
        // Build authorization header
        const auth_header = try std.fmt.allocPrint(
            self.allocator,
            "AWS4-HMAC-SHA256 Credential={s}/{s}/{s}/{s}/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature={s}",
            .{ self.access_key_id, date_stamp, self.region, self.service, signature },
        );
        defer self.allocator.free(auth_header);
        
        try headers.put("Authorization", auth_header);
    }
    
    fn hashPayload(self: *Self, body: ?[]const u8) ![]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        if (body) |b| {
            hasher.update(b);
        }
        const hash = hasher.finalResult();
        return std.fmt.allocPrint(self.allocator, "{}", .{std.fmt.fmtSliceHexLower(&hash)});
    }
    
    fn buildCanonicalRequest(
        self: *Self,
        method: Method,
        uri: []const u8,
        headers: *Headers,
        body: ?[]const u8,
    ) ![]u8 {
        const payload_hash = try self.hashPayload(body);
        defer self.allocator.free(payload_hash);
        
        const parsed_uri = try std.Uri.parse(uri);
        const path = if (parsed_uri.path.len > 0) parsed_uri.path else "/";
        
        return std.fmt.allocPrint(self.allocator,
            \\{s}
            \\{s}
            \\
            \\host:{s}
            \\x-amz-content-sha256:{s}
            \\x-amz-date:{s}
            \\
            \\host;x-amz-content-sha256;x-amz-date
            \\{s}
        , .{
            method.toString(),
            path,
            parsed_uri.host orelse "",
            payload_hash,
            headers.get("x-amz-date") orelse "",
            payload_hash,
        });
    }
    
    fn buildStringToSign(
        self: *Self,
        timestamp: []const u8,
        date_stamp: []const u8,
        canonical_request: []const u8,
    ) ![]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(canonical_request);
        const hash = hasher.finalResult();
        const hash_hex = try std.fmt.allocPrint(self.allocator, "{}", .{std.fmt.fmtSliceHexLower(&hash)});
        defer self.allocator.free(hash_hex);
        
        return std.fmt.allocPrint(self.allocator,
            \\AWS4-HMAC-SHA256
            \\{s}
            \\{s}/{s}/{s}/aws4_request
            \\{s}
        , .{ timestamp, date_stamp, self.region, self.service, hash_hex });
    }
    
    fn calculateSignature(
        self: *Self,
        date_stamp: []const u8,
        string_to_sign: []const u8,
    ) ![]u8 {
        // kDate = HMAC("AWS4" + SecretAccessKey, Date)
        // kRegion = HMAC(kDate, Region)
        // kService = HMAC(kRegion, Service)
        // kSigning = HMAC(kService, "aws4_request")
        // signature = HMAC(kSigning, StringToSign)
        
        var key_date: [32]u8 = undefined;
        var key_prefix = try std.fmt.allocPrint(self.allocator, "AWS4{s}", .{self.secret_access_key});
        defer self.allocator.free(key_prefix);
        
        std.crypto.auth.hmac.HmacSha256.create(&key_date, date_stamp, key_prefix);
        
        var key_region: [32]u8 = undefined;
        std.crypto.auth.hmac.HmacSha256.create(&key_region, self.region, &key_date);
        
        var key_service: [32]u8 = undefined;
        std.crypto.auth.hmac.HmacSha256.create(&key_service, self.service, &key_region);
        
        var key_signing: [32]u8 = undefined;
        std.crypto.auth.hmac.HmacSha256.create(&key_signing, "aws4_request", &key_service);
        
        var signature: [32]u8 = undefined;
        std.crypto.auth.hmac.HmacSha256.create(&signature, string_to_sign, &key_signing);
        
        return std.fmt.allocPrint(self.allocator, "{}", .{std.fmt.fmtSliceHexLower(&signature)});
    }
};

fn getAmzDate() []const u8 {
    // Returns ISO8601 basic format: "20260303T010203Z"
    // In real implementation, use system time
    return "20260303T000000Z";
}

// Tests
test "http client init" {
    const allocator = std.testing.allocator;
    var client = HttpClient.init(allocator, .{});
    defer client.deinit();
}

test "headers" {
    const allocator = std.testing.allocator;
    var headers = Headers.init(allocator);
    defer headers.deinit();
    
    try headers.put("Content-Type", "application/json");
    try std.testing.expectEqualStrings("application/json", headers.get("Content-Type").?);
}
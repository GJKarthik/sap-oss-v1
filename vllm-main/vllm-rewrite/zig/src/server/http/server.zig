//! HTTP Server for vLLM API
//!
//! Provides an OpenAI-compatible REST API for the vLLM inference engine.
//! Supports:
//! - /v1/completions
//! - /v1/chat/completions
//! - /v1/models
//! - /health

const std = @import("std");
const logging = @import("../../utils/logging.zig");
const config = @import("../../utils/config.zig");
const engine = @import("../../engine/engine_core.zig");
const types = @import("../../engine/types.zig");

const log = logging.scoped(.http_server);

/// HTTP request context
pub const RequestContext = struct {
    /// Client connection
    connection: std.net.Server.Connection,
    /// Allocator for this request
    allocator: std.mem.Allocator,
    /// Request ID for tracking
    request_id: u64,
    /// Start time
    start_time: i64,
};

/// HTTP server configuration
pub const HttpServerConfig = struct {
    /// Host to bind to
    host: []const u8 = "0.0.0.0",
    /// Port to listen on
    port: u16 = 8000,
    /// Maximum concurrent connections
    max_connections: u32 = 1000,
    /// Request timeout (seconds)
    timeout_seconds: u32 = 600,
    /// Whether to enable CORS
    enable_cors: bool = true,
    /// API key for authentication (null = disabled)
    api_key: ?[]const u8 = null,
};

/// HTTP Server
pub const HttpServer = struct {
    /// Memory allocator
    allocator: std.mem.Allocator,
    /// Server configuration
    config: HttpServerConfig,
    /// Engine reference
    engine: *engine.EngineCore,
    /// TCP server
    server: ?std.net.Server,
    /// Whether server is running
    running: bool,
    /// Request counter
    request_counter: u64,
    /// Model name to serve
    model_name: []const u8,

    const Self = @This();

    /// Initialize the HTTP server
    pub fn init(
        allocator: std.mem.Allocator,
        server_config: HttpServerConfig,
        eng: *engine.EngineCore,
        model_name: []const u8,
    ) !*Self {
        var self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .config = server_config,
            .engine = eng,
            .server = null,
            .running = false,
            .request_counter = 0,
            .model_name = model_name,
        };

        return self;
    }

    /// Deinitialize the server
    pub fn deinit(self: *Self) void {
        self.stop();
        self.allocator.destroy(self);
    }

    /// Start the server
    pub fn start(self: *Self) !void {
        const address = std.net.Address.parseIp(self.config.host, self.config.port) catch |err| {
            log.err("Failed to parse address: {any}", .{err});
            return err;
        };

        self.server = std.net.Address.listen(address, .{
            .reuse_address = true,
        }) catch |err| {
            log.err("Failed to start server: {any}", .{err});
            return err;
        };

        self.running = true;
        log.info("HTTP server started on {s}:{d}", .{ self.config.host, self.config.port });

        // Accept connections in a loop
        while (self.running) {
            if (self.server) |*server| {
                const connection = server.accept() catch |err| {
                    if (self.running) {
                        log.err("Failed to accept connection: {any}", .{err});
                    }
                    continue;
                };

                // Handle connection (would spawn thread in production)
                self.handleConnection(connection) catch |err| {
                    log.err("Error handling connection: {any}", .{err});
                };
            }
        }
    }

    /// Stop the server
    pub fn stop(self: *Self) void {
        self.running = false;
        if (self.server) |*server| {
            server.deinit();
            self.server = null;
        }
        log.info("HTTP server stopped", .{});
    }

    /// Handle a client connection
    fn handleConnection(self: *Self, connection: std.net.Server.Connection) !void {
        defer connection.stream.close();

        var buf: [8192]u8 = undefined;
        const bytes_read = try connection.stream.read(&buf);
        if (bytes_read == 0) return;

        const request_data = buf[0..bytes_read];

        // Parse HTTP request
        const request = try self.parseHttpRequest(request_data);

        // Generate unique request ID
        self.request_counter += 1;
        const request_id = self.request_counter;

        log.debug("Request {d}: {s} {s}", .{ request_id, request.method, request.path });

        // Route request
        const response = try self.routeRequest(request, request_id);

        // Send response
        try self.sendResponse(connection, response);
    }

    /// HTTP Request structure
    const HttpRequest = struct {
        method: []const u8,
        path: []const u8,
        headers: std.StringHashMap([]const u8),
        body: []const u8,
    };

    /// Parse HTTP request from raw bytes
    fn parseHttpRequest(self: *Self, data: []const u8) !HttpRequest {
        var headers = std.StringHashMap([]const u8).init(self.allocator);

        // Find end of headers
        var header_end: usize = 0;
        for (data, 0..) |byte, i| {
            if (i >= 3 and
                data[i - 3] == '\r' and data[i - 2] == '\n' and
                data[i - 1] == '\r' and data[i] == '\n')
            {
                header_end = i + 1;
                break;
            }
        }

        if (header_end == 0) {
            header_end = data.len;
        }

        // Parse first line
        var line_iter = std.mem.splitSequence(u8, data[0..header_end], "\r\n");
        const first_line = line_iter.next() orelse return error.InvalidRequest;

        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse return error.InvalidRequest;
        const path = parts.next() orelse return error.InvalidRequest;

        // Parse headers
        while (line_iter.next()) |line| {
            if (line.len == 0) break;

            if (std.mem.indexOf(u8, line, ": ")) |sep| {
                const key = line[0..sep];
                const value = line[sep + 2 ..];
                try headers.put(key, value);
            }
        }

        // Body is everything after headers
        const body = if (header_end < data.len) data[header_end..] else "";

        return HttpRequest{
            .method = method,
            .path = path,
            .headers = headers,
            .body = body,
        };
    }

    /// HTTP Response structure
    const HttpResponse = struct {
        status_code: u16,
        status_text: []const u8,
        content_type: []const u8,
        body: []const u8,
    };

    /// Route request to appropriate handler
    fn routeRequest(self: *Self, request: HttpRequest, request_id: u64) !HttpResponse {
        _ = request_id;

        // Check authentication if required
        if (self.config.api_key) |api_key| {
            const auth_header = request.headers.get("Authorization");
            if (auth_header == null) {
                return self.errorResponse(401, "Unauthorized", "Missing API key");
            }

            const bearer_prefix = "Bearer ";
            if (!std.mem.startsWith(u8, auth_header.?, bearer_prefix)) {
                return self.errorResponse(401, "Unauthorized", "Invalid API key format");
            }

            const provided_key = auth_header.?[bearer_prefix.len..];
            if (!std.mem.eql(u8, provided_key, api_key)) {
                return self.errorResponse(401, "Unauthorized", "Invalid API key");
            }
        }

        // Route based on path
        if (std.mem.eql(u8, request.path, "/health")) {
            return self.handleHealth();
        } else if (std.mem.eql(u8, request.path, "/v1/models")) {
            return self.handleModels();
        } else if (std.mem.eql(u8, request.path, "/v1/completions")) {
            return self.handleCompletions(request);
        } else if (std.mem.eql(u8, request.path, "/v1/chat/completions")) {
            return self.handleChatCompletions(request);
        } else {
            return self.errorResponse(404, "Not Found", "Endpoint not found");
        }
    }

    /// Health check endpoint
    fn handleHealth(self: *Self) HttpResponse {
        const state = self.engine.getState();
        const state_str = switch (state) {
            .ready => "ready",
            .running => "running",
            .initializing => "initializing",
            else => "error",
        };

        const body = std.fmt.allocPrint(self.allocator,
            \\{{"status": "ok", "engine_state": "{s}"}}
        , .{state_str}) catch return self.errorResponse(500, "Internal Server Error", "");

        return HttpResponse{
            .status_code = 200,
            .status_text = "OK",
            .content_type = "application/json",
            .body = body,
        };
    }

    /// Models list endpoint
    fn handleModels(self: *Self) HttpResponse {
        const body = std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "object": "list",
            \\  "data": [
            \\    {{
            \\      "id": "{s}",
            \\      "object": "model",
            \\      "created": 1700000000,
            \\      "owned_by": "vllm"
            \\    }}
            \\  ]
            \\}}
        , .{self.model_name}) catch return self.errorResponse(500, "Internal Server Error", "");

        return HttpResponse{
            .status_code = 200,
            .status_text = "OK",
            .content_type = "application/json",
            .body = body,
        };
    }

    /// Completions endpoint
    fn handleCompletions(self: *Self, request: HttpRequest) HttpResponse {
        // Parse request body
        const completion_request = self.parseCompletionRequest(request.body) catch {
            return self.errorResponse(400, "Bad Request", "Invalid request body");
        };

        // Create sampling params
        const params = types.SamplingParams{
            .max_tokens = completion_request.max_tokens,
            .temperature = completion_request.temperature,
            .top_p = completion_request.top_p,
        };

        // Add request to engine (would need tokenization first)
        _ = self.engine.addRequest(
            null,
            &[_]u32{ 1, 2, 3, 4, 5 }, // Placeholder tokens
            params,
        ) catch {
            return self.errorResponse(500, "Internal Server Error", "Failed to add request");
        };

        // For now, return a placeholder response
        const body = std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "id": "cmpl-{d}",
            \\  "object": "text_completion",
            \\  "created": {d},
            \\  "model": "{s}",
            \\  "choices": [
            \\    {{
            \\      "text": "This is a placeholder response.",
            \\      "index": 0,
            \\      "finish_reason": "length"
            \\    }}
            \\  ],
            \\  "usage": {{
            \\    "prompt_tokens": 5,
            \\    "completion_tokens": 10,
            \\    "total_tokens": 15
            \\  }}
            \\}}
        , .{
            self.request_counter,
            std.time.timestamp(),
            self.model_name,
        }) catch return self.errorResponse(500, "Internal Server Error", "");

        return HttpResponse{
            .status_code = 200,
            .status_text = "OK",
            .content_type = "application/json",
            .body = body,
        };
    }

    /// Chat completions endpoint
    fn handleChatCompletions(self: *Self, request: HttpRequest) HttpResponse {
        _ = request;

        // Parse chat request and format prompt
        // For now, return a placeholder response

        const body = std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "id": "chatcmpl-{d}",
            \\  "object": "chat.completion",
            \\  "created": {d},
            \\  "model": "{s}",
            \\  "choices": [
            \\    {{
            \\      "index": 0,
            \\      "message": {{
            \\        "role": "assistant",
            \\        "content": "This is a placeholder response from the vLLM server."
            \\      }},
            \\      "finish_reason": "stop"
            \\    }}
            \\  ],
            \\  "usage": {{
            \\    "prompt_tokens": 10,
            \\    "completion_tokens": 15,
            \\    "total_tokens": 25
            \\  }}
            \\}}
        , .{
            self.request_counter,
            std.time.timestamp(),
            self.model_name,
        }) catch return self.errorResponse(500, "Internal Server Error", "");

        return HttpResponse{
            .status_code = 200,
            .status_text = "OK",
            .content_type = "application/json",
            .body = body,
        };
    }

    /// Completion request structure
    const CompletionRequest = struct {
        prompt: []const u8 = "",
        max_tokens: ?u32 = 256,
        temperature: f32 = 1.0,
        top_p: f32 = 1.0,
        n: u32 = 1,
        stream: bool = false,
        stop: ?[]const []const u8 = null,
    };

    /// Parse completion request from JSON
    fn parseCompletionRequest(self: *Self, body: []const u8) !CompletionRequest {
        _ = self;
        // Simple JSON parsing (would use proper JSON parser in production)
        var request = CompletionRequest{};

        // Extract max_tokens
        if (std.mem.indexOf(u8, body, "\"max_tokens\":")) |pos| {
            const start = pos + 13;
            var end = start;
            while (end < body.len and (body[end] >= '0' and body[end] <= '9')) {
                end += 1;
            }
            if (end > start) {
                request.max_tokens = std.fmt.parseInt(u32, body[start..end], 10) catch 256;
            }
        }

        // Extract temperature
        if (std.mem.indexOf(u8, body, "\"temperature\":")) |pos| {
            const start = pos + 14;
            var end = start;
            while (end < body.len and (body[end] >= '0' and body[end] <= '9' or body[end] == '.')) {
                end += 1;
            }
            if (end > start) {
                request.temperature = std.fmt.parseFloat(f32, body[start..end]) catch 1.0;
            }
        }

        return request;
    }

    /// Create error response
    fn errorResponse(self: *Self, status_code: u16, status_text: []const u8, message: []const u8) HttpResponse {
        const body = std.fmt.allocPrint(self.allocator,
            \\{{"error": {{"message": "{s}", "type": "error", "code": {d}}}}}
        , .{ message, status_code }) catch "";

        return HttpResponse{
            .status_code = status_code,
            .status_text = status_text,
            .content_type = "application/json",
            .body = body,
        };
    }

    /// Send HTTP response
    fn sendResponse(self: *Self, connection: std.net.Server.Connection, response: HttpResponse) !void {
        var response_buf: [16384]u8 = undefined;

        const cors_headers = if (self.config.enable_cors)
            "Access-Control-Allow-Origin: *\r\n" ++
                "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" ++
                "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
        else
            "";

        const written = std.fmt.bufPrint(&response_buf,
            \\HTTP/1.1 {d} {s}
            \\Content-Type: {s}
            \\Content-Length: {d}
            \\{s}
            \\
            \\{s}
        , .{
            response.status_code,
            response.status_text,
            response.content_type,
            response.body.len,
            cors_headers,
            response.body,
        }) catch return error.ResponseTooLarge;

        _ = try connection.stream.write(written);
    }
};

// ============================================
// Tests
// ============================================

test "HttpServer initialization" {
    const allocator = std.testing.allocator;

    // Would need mock engine for proper testing
    _ = allocator;
}
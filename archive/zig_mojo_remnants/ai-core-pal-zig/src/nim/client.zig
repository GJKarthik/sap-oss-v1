//! NVIDIA NIM Client
//! HTTP client for NVIDIA Inference Microservices (NIM) endpoints
//! Supports embedding, completion, and chat inference via NIM API

const std = @import("std");
const builtin = @import("builtin");
const json_utils = @import("json_utils.zig");

const log = std.log.scoped(.nim_client);

// ============================================================================
// NIM Configuration
// ============================================================================

pub const NimConfig = struct {
    /// NIM endpoint URL (e.g., http://nim-llm:8000 or https://integrate.api.nvidia.com)
    endpoint: []const u8 = "http://localhost:8000",
    /// API key for NVIDIA API (NGC or AI Foundation)
    api_key: ?[]const u8 = null,
    /// Model name (e.g., meta/llama3-8b-instruct, nvidia/embed-qa-4)
    model: []const u8 = "nvidia/nv-embed-v1",
    /// Request timeout in milliseconds
    timeout_ms: u32 = 30000,
    /// Max retries on failure
    max_retries: u8 = 3,
    /// Enable streaming responses
    streaming: bool = false,
};

// ============================================================================
// NIM Request/Response Types
// ============================================================================

pub const EmbeddingRequest = struct {
    model: []const u8,
    input: []const []const u8,
    encoding_format: []const u8 = "float",
    truncate: []const u8 = "END",
};

pub const EmbeddingResponse = struct {
    object: []const u8,
    model: []const u8,
    usage: Usage,
    data: []const EmbeddingData,

    pub const EmbeddingData = struct {
        index: usize,
        embedding: []const f32,
        object: []const u8,
    };

    pub const Usage = struct {
        prompt_tokens: u32,
        total_tokens: u32,
    };
};

pub const ChatRequest = struct {
    model: []const u8,
    messages: []const Message,
    temperature: f32 = 0.7,
    max_tokens: u32 = 1024,
    top_p: f32 = 1.0,
    stream: bool = false,

    pub const Message = struct {
        role: []const u8, // "system", "user", "assistant"
        content: []const u8,
    };
};

pub const ChatResponse = struct {
    id: []const u8,
    object: []const u8,
    created: i64,
    model: []const u8,
    choices: []const Choice,
    usage: Usage,

    pub const Choice = struct {
        index: usize,
        message: Message,
        finish_reason: []const u8,

        pub const Message = struct {
            role: []const u8,
            content: []const u8,
        };
    };

    pub const Usage = struct {
        prompt_tokens: u32,
        completion_tokens: u32,
        total_tokens: u32,
    };
};

// ============================================================================
// NIM Client
// ============================================================================

pub const NimClient = struct {
    allocator: std.mem.Allocator,
    config: NimConfig,

    // Statistics
    requests_sent: std.atomic.Value(u64),
    requests_succeeded: std.atomic.Value(u64),
    requests_failed: std.atomic.Value(u64),
    total_latency_ms: std.atomic.Value(u64),
    total_tokens: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, config: NimConfig) !*NimClient {
        const client = try allocator.create(NimClient);
        client.* = .{
            .allocator = allocator,
            .config = config,
            .requests_sent = std.atomic.Value(u64).init(0),
            .requests_succeeded = std.atomic.Value(u64).init(0),
            .requests_failed = std.atomic.Value(u64).init(0),
            .total_latency_ms = std.atomic.Value(u64).init(0),
            .total_tokens = std.atomic.Value(u64).init(0),
        };

        log.info("NIM Client initialized:", .{});
        log.info("  Endpoint: {s}", .{config.endpoint});
        log.info("  Model: {s}", .{config.model});
        log.info("  Timeout: {}ms", .{config.timeout_ms});

        return client;
    }

    pub fn deinit(self: *NimClient) void {
        self.allocator.destroy(self);
        log.info("NIM Client destroyed", .{});
    }

    /// Generate embeddings via NIM
    pub fn embed(self: *NimClient, texts: []const []const u8) !EmbeddingResult {
        const start = std.time.milliTimestamp();
        _ = self.requests_sent.fetchAdd(1, .monotonic);

        // Build request payload
        const request_body = try self.buildEmbeddingRequest(texts);
        defer self.allocator.free(request_body);

        // Make HTTP request with retry
        const response = try self.httpPost("/v1/embeddings", request_body);
        defer self.allocator.free(response);

        // Parse response
        const result = try self.parseEmbeddingResponse(response, texts.len);

        const elapsed = std.time.milliTimestamp() - start;
        _ = self.requests_succeeded.fetchAdd(1, .monotonic);
        _ = self.total_latency_ms.fetchAdd(@intCast(elapsed), .monotonic);

        return result;
    }

    /// Chat completion via NIM
    pub fn chat(self: *NimClient, messages: []const ChatRequest.Message) !ChatResult {
        const start = std.time.milliTimestamp();
        _ = self.requests_sent.fetchAdd(1, .monotonic);

        // Build request payload
        const request_body = try self.buildChatRequest(messages);
        defer self.allocator.free(request_body);

        // Make HTTP request
        const response = try self.httpPost("/v1/chat/completions", request_body);
        defer self.allocator.free(response);

        // Parse response
        const result = try self.parseChatResponse(response);

        const elapsed = std.time.milliTimestamp() - start;
        _ = self.requests_succeeded.fetchAdd(1, .monotonic);
        _ = self.total_latency_ms.fetchAdd(@intCast(elapsed), .monotonic);
        _ = self.total_tokens.fetchAdd(result.total_tokens, .monotonic);

        return result;
    }

    // =========================================================================
    // HTTP Layer - Real implementation with retry and backoff
    // =========================================================================

    fn httpPost(self: *NimClient, path: []const u8, body: []const u8) ![]u8 {
        var retry: u8 = 0;
        while (retry <= self.config.max_retries) : (retry += 1) {
            const result = self.httpPostOnce(path, body) catch |err| {
                if (retry < self.config.max_retries) {
                    const wait_ms: u64 = @as(u64, 100) << @intCast(retry);
                    log.warn("NIM request failed (attempt {}/{}): {}, retrying in {}ms", .{
                        retry + 1, self.config.max_retries + 1, err, wait_ms,
                    });
                    std.time.sleep(wait_ms * std.time.ns_per_ms);
                    continue;
                }
                _ = self.requests_failed.fetchAdd(1, .monotonic);
                return err;
            };
            return result;
        }
        return error.MaxRetriesExceeded;
    }

    fn httpPostOnce(self: *NimClient, path: []const u8, body: []const u8) ![]u8 {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        // Build full URL
        var url_buf: [2048]u8 = undefined;
        const url_str = std.fmt.bufPrint(&url_buf, "{s}{s}", .{ self.config.endpoint, path }) catch
            return error.UrlTooLong;

        const uri = std.Uri.parse(url_str) catch return error.InvalidUri;

        var server_header_buf: [16 * 1024]u8 = undefined;
        var req = client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Accept", .value = "application/json" },
            },
        }) catch |err| {
            log.err("Failed to open HTTP connection: {}", .{err});
            return error.ConnectionFailed;
        };
        defer req.deinit();

        // Set API key if present
        if (self.config.api_key) |key| {
            var auth_buf: [1024]u8 = undefined;
            const auth_val = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{key}) catch
                return error.ApiKeyTooLong;
            req.headers.authorization = .{ .override = auth_val };
        }

        req.transfer_encoding = .{ .content_length = body.len };
        req.send() catch |err| {
            log.err("Failed to send HTTP request: {}", .{err});
            return error.SendFailed;
        };
        req.writeAll(body) catch |err| {
            log.err("Failed to write request body: {}", .{err});
            return error.WriteFailed;
        };
        req.finish() catch |err| {
            log.err("Failed to finish request: {}", .{err});
            return error.FinishFailed;
        };
        req.wait() catch |err| {
            log.err("Failed to wait for response: {}", .{err});
            return error.WaitFailed;
        };

        if (req.status != .ok) {
            log.err("NIM API returned status {}", .{req.status});
            return error.NimApiError;
        }

        // Read response body
        var response_body = std.ArrayListUnmanaged(u8){};
        errdefer response_body.deinit(self.allocator);

        var buf: [8192]u8 = undefined;
        while (true) {
            const n = req.reader().read(&buf) catch |err| {
                log.err("Failed to read response: {}", .{err});
                return error.ReadFailed;
            };
            if (n == 0) break;
            try response_body.appendSlice(self.allocator, buf[0..n]);
        }

        return response_body.toOwnedSlice(self.allocator);
    }

    fn buildEmbeddingRequest(self: *NimClient, texts: []const []const u8) ![]u8 {
        var list = std.ArrayListUnmanaged(u8){};
        errdefer list.deinit(self.allocator);

        try list.appendSlice(self.allocator, "{\"model\":\"");
        try list.appendSlice(self.allocator, self.config.model);
        try list.appendSlice(self.allocator, "\",\"input\":[");

        for (texts, 0..) |text, i| {
            if (i > 0) try list.appendSlice(self.allocator, ",");
            const escaped = try json_utils.jsonEscape(self.allocator, text);
            defer self.allocator.free(escaped);
            try list.appendSlice(self.allocator, "\"");
            try list.appendSlice(self.allocator, escaped);
            try list.appendSlice(self.allocator, "\"");
        }

        try list.appendSlice(self.allocator, "],\"encoding_format\":\"float\"}");

        return list.toOwnedSlice(self.allocator);
    }

    fn buildChatRequest(self: *NimClient, messages: []const ChatRequest.Message) ![]u8 {
        var list = std.ArrayListUnmanaged(u8){};
        errdefer list.deinit(self.allocator);

        try list.appendSlice(self.allocator, "{\"model\":\"");
        try list.appendSlice(self.allocator, self.config.model);
        try list.appendSlice(self.allocator, "\",\"messages\":[");

        for (messages, 0..) |msg, i| {
            if (i > 0) try list.appendSlice(self.allocator, ",");
            const escaped_content = try json_utils.jsonEscape(self.allocator, msg.content);
            defer self.allocator.free(escaped_content);
            try list.appendSlice(self.allocator, "{\"role\":\"");
            try list.appendSlice(self.allocator, msg.role);
            try list.appendSlice(self.allocator, "\",\"content\":\"");
            try list.appendSlice(self.allocator, escaped_content);
            try list.appendSlice(self.allocator, "\"}");
        }

        try list.appendSlice(self.allocator, "],\"max_tokens\":1024}");

        return list.toOwnedSlice(self.allocator);
    }

    fn parseEmbeddingResponse(self: *NimClient, response: []const u8, expected_count: usize) !EmbeddingResult {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch |err| {
            log.err("Failed to parse NIM embedding response: {}", .{err});
            return error.InvalidResponse;
        };
        defer parsed.deinit();

        const root = parsed.value;
        const data_array = root.object.get("data") orelse return error.MissingField;

        var embeddings = try self.allocator.alloc([]f32, expected_count);
        errdefer {
            for (embeddings) |emb| self.allocator.free(emb);
            self.allocator.free(embeddings);
        }

        for (data_array.array.items, 0..) |item, i| {
            if (i >= expected_count) break;
            const emb_array = item.object.get("embedding") orelse return error.MissingField;
            const emb_items = emb_array.array.items;
            embeddings[i] = try self.allocator.alloc(f32, emb_items.len);
            for (emb_items, 0..) |val, j| {
                embeddings[i][j] = @floatCast(val.float);
            }
        }

        const usage = root.object.get("usage") orelse return error.MissingField;
        const prompt_tokens_val = usage.object.get("prompt_tokens") orelse return error.MissingField;
        const total_tokens_val = usage.object.get("total_tokens") orelse return error.MissingField;
        const prompt_tokens: u32 = @intCast(prompt_tokens_val.integer);
        const total_tokens: u32 = @intCast(total_tokens_val.integer);

        return .{
            .embeddings = embeddings,
            .prompt_tokens = prompt_tokens,
            .total_tokens = total_tokens,
        };
    }

    fn parseChatResponse(self: *NimClient, response: []const u8) !ChatResult {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch |err| {
            log.err("Failed to parse NIM chat response: {}", .{err});
            return error.InvalidResponse;
        };
        defer parsed.deinit();

        const root = parsed.value;
        const choices = root.object.get("choices") orelse return error.MissingField;
        const first_choice = choices.array.items[0];
        const message = first_choice.object.get("message") orelse return error.MissingField;
        const content_val = message.object.get("content") orelse return error.MissingField;

        const content = try self.allocator.dupe(u8, content_val.string);

        const usage = root.object.get("usage") orelse return error.MissingField;
        const prompt_tokens_val = usage.object.get("prompt_tokens") orelse return error.MissingField;
        const completion_tokens_val = usage.object.get("completion_tokens") orelse return error.MissingField;
        const total_tokens_val = usage.object.get("total_tokens") orelse return error.MissingField;

        return .{
            .content = content,
            .prompt_tokens = @intCast(prompt_tokens_val.integer),
            .completion_tokens = @intCast(completion_tokens_val.integer),
            .total_tokens = @intCast(total_tokens_val.integer),
            .finish_reason = "stop",
        };
    }

    // =========================================================================
    // Statistics
    // =========================================================================

    pub fn getStats(self: *const NimClient) NimStats {
        const sent = self.requests_sent.load(.acquire);
        const latency = self.total_latency_ms.load(.acquire);

        return .{
            .requests_sent = sent,
            .requests_succeeded = self.requests_succeeded.load(.acquire),
            .requests_failed = self.requests_failed.load(.acquire),
            .total_tokens = self.total_tokens.load(.acquire),
            .avg_latency_ms = if (sent > 0) latency / sent else 0,
        };
    }
};

// ============================================================================
// Result Types
// ============================================================================

pub const EmbeddingResult = struct {
    embeddings: [][]f32,
    prompt_tokens: u32,
    total_tokens: u32,

    pub fn deinit(self: *EmbeddingResult, allocator: std.mem.Allocator) void {
        for (self.embeddings) |emb| {
            allocator.free(emb);
        }
        allocator.free(self.embeddings);
    }
};

pub const ChatResult = struct {
    content: []u8,
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
    finish_reason: []const u8,

    pub fn deinit(self: *ChatResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

pub const NimStats = struct {
    requests_sent: u64,
    requests_succeeded: u64,
    requests_failed: u64,
    total_tokens: u64,
    avg_latency_ms: u64,
};

// ============================================================================
// Tests
// ============================================================================

test "NimClient init and deinit" {
    const client = try NimClient.init(std.testing.allocator, .{});
    defer client.deinit();

    const stats = client.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.requests_sent);
}

test "buildEmbeddingRequest escapes special chars" {
    const client = try NimClient.init(std.testing.allocator, .{
        .model = "test-model",
    });
    defer client.deinit();

    const texts = [_][]const u8{ "hello \"world\"", "line1\nline2" };
    const body = try client.buildEmbeddingRequest(&texts);
    defer client.allocator.free(body);

    // Should contain escaped quotes inside strings
    try std.testing.expect(std.mem.indexOf(u8, body, "hello \\\"world\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "line1\\nline2") != null);
}

test "buildChatRequest escapes special chars" {
    const client = try NimClient.init(std.testing.allocator, .{
        .model = "test-model",
    });
    defer client.deinit();

    const messages = [_]ChatRequest.Message{
        .{ .role = "user", .content = "Say \"hello\"\nworld" },
    };
    const body = try client.buildChatRequest(&messages);
    defer client.allocator.free(body);

    // Should contain escaped quotes and newlines
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"hello\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\nworld") != null);
}

test "parseEmbeddingResponse parses valid JSON" {
    const client = try NimClient.init(std.testing.allocator, .{});
    defer client.deinit();

    const response =
        \\{"object":"list","model":"nvidia/nv-embed-v1","usage":{"prompt_tokens":10,"total_tokens":10},"data":[{"index":0,"embedding":[0.1,0.2,0.3],"object":"embedding"}]}
    ;

    var result = try client.parseEmbeddingResponse(response, 1);
    defer result.deinit(client.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.embeddings.len);
    try std.testing.expectEqual(@as(usize, 3), result.embeddings[0].len);
    try std.testing.expectEqual(@as(u32, 10), result.prompt_tokens);
}

test "parseChatResponse parses valid JSON" {
    const client = try NimClient.init(std.testing.allocator, .{});
    defer client.deinit();

    const response =
        \\{"id":"chatcmpl-123","object":"chat.completion","created":1677652288,"model":"test","choices":[{"index":0,"message":{"role":"assistant","content":"Hello there!"},"finish_reason":"stop"}],"usage":{"prompt_tokens":9,"completion_tokens":12,"total_tokens":21}}
    ;

    var result = try client.parseChatResponse(response);
    defer result.deinit(client.allocator);

    try std.testing.expectEqualStrings("Hello there!", result.content);
    try std.testing.expectEqual(@as(u32, 21), result.total_tokens);
}
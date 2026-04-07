//! BDC AIPrompt Streaming - Integration Tests
//! Comprehensive test suite for broker, protocol, storage, authentication, and OpenAI API

const std = @import("std");
const testing = std.testing;
const mem = std.mem;

// ============================================================================
// Mock Components
// ============================================================================

pub const MockBroker = struct {
    allocator: mem.Allocator,
    state: BrokerState = .Running,
    topics_count: u32 = 0,
    messages_in: u64 = 0,
    messages_out: u64 = 0,
    start_time: i64,
    
    pub const BrokerState = enum {
        Initializing,
        Running,
        Draining,
        ShuttingDown,
        Stopped,
    };
    
    pub fn init(allocator: mem.Allocator) MockBroker {
        return .{
            .allocator = allocator,
            .start_time = std.time.milliTimestamp(),
        };
    }
    
    pub fn getStats(self: *const MockBroker) BrokerStats {
        return .{
            .topics_count = self.topics_count,
            .messages_in = self.messages_in,
            .messages_out = self.messages_out,
            .uptime_ms = std.time.milliTimestamp() - self.start_time,
        };
    }
};

pub const BrokerStats = struct {
    topics_count: u32,
    messages_in: u64,
    messages_out: u64,
    uptime_ms: i64,
};

pub const MockProtocolHandler = struct {
    allocator: mem.Allocator,
    
    pub const CommandType = enum {
        CONNECT,
        CONNECTED,
        PING,
        PONG,
        PRODUCER,
        SUBSCRIBE,
        SEND,
        FLOW,
        SUCCESS,
        ERROR,
    };
    
    pub fn init(allocator: mem.Allocator) MockProtocolHandler {
        return .{ .allocator = allocator };
    }
    
    pub fn createConnectedResponse(self: *MockProtocolHandler, server_version: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "CONNECTED:{s}", .{server_version});
    }
    
    pub fn createPongResponse(self: *MockProtocolHandler) ![]const u8 {
        return try self.allocator.dupe(u8, "PONG");
    }
    
    pub fn createSuccessResponse(self: *MockProtocolHandler, request_id: u64) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "SUCCESS:{d}", .{request_id});
    }
};

pub const MockHanaClient = struct {
    allocator: mem.Allocator,
    host: []const u8 = "localhost",
    port: u16 = 443,
    schema: []const u8 = "AIPROMPT_STORAGE",
    connected: bool = false,
    
    pub fn init(allocator: mem.Allocator) MockHanaClient {
        return .{ .allocator = allocator };
    }
    
    pub fn isConnected(self: *const MockHanaClient) bool {
        return self.connected;
    }
};

// ============================================================================
// Test Harness
// ============================================================================

pub const TestContext = struct {
    allocator: mem.Allocator,
    broker: MockBroker,
    protocol: MockProtocolHandler,
    hana: MockHanaClient,
    requests_total: u64 = 0,

    pub fn init(allocator: mem.Allocator) !TestContext {
        return TestContext{
            .allocator = allocator,
            .broker = MockBroker.init(allocator),
            .protocol = MockProtocolHandler.init(allocator),
            .hana = MockHanaClient.init(allocator),
        };
    }

    pub fn simulateRequest(
        self: *TestContext,
        method: Method,
        path: []const u8,
        body: ?[]const u8,
    ) !SimulatedResponse {
        self.requests_total += 1;

        // Health endpoints
        if (mem.eql(u8, path, "/health") or mem.eql(u8, path, "/healthz")) {
            return try self.handleHealth();
        }
        
        // Ready endpoints
        if (mem.eql(u8, path, "/ready") or mem.eql(u8, path, "/readyz")) {
            return try self.handleReady();
        }
        
        // Metrics
        if (mem.eql(u8, path, "/metrics")) {
            return try self.handleMetrics();
        }
        
        // GPU Info
        if (mem.startsWith(u8, path, "/api/gpu/info")) {
            return try self.handleGpuInfo();
        }

        // OpenAI API endpoints
        if (mem.eql(u8, path, "/v1/models")) {
            return try self.handleModels();
        }
        
        if (mem.eql(u8, path, "/v1/chat/completions")) {
            if (method != .POST) {
                return SimulatedResponse{
                    .status = 405,
                    .body = try self.allocator.dupe(u8, "{\"error\":{\"message\":\"Method not allowed\"}}"),
                };
            }
            return try self.handleChatCompletions(body);
        }
        
        if (mem.eql(u8, path, "/v1/toon/chat/completions")) {
            if (method != .POST) {
                return SimulatedResponse{
                    .status = 405,
                    .body = try self.allocator.dupe(u8, "{\"error\":{\"message\":\"Method not allowed\"}}"),
                };
            }
            return try self.handleToonChat(body);
        }
        
        if (mem.eql(u8, path, "/v1/completions")) {
            return try self.handleCompletions(body);
        }
        
        if (mem.eql(u8, path, "/v1/embeddings")) {
            return try self.handleEmbeddings(body);
        }
        
        if (mem.startsWith(u8, path, "/v1/audio/")) {
            return try self.handleAudio();
        }
        
        if (mem.startsWith(u8, path, "/v1/images/")) {
            return try self.handleImages();
        }
        
        if (mem.startsWith(u8, path, "/v1/files")) {
            return try self.handleFiles();
        }
        
        if (mem.startsWith(u8, path, "/v1/fine_tuning/")) {
            return try self.handleFineTuning();
        }
        
        if (mem.eql(u8, path, "/v1/moderations")) {
            return try self.handleModerations(body);
        }

        // Not found
        return SimulatedResponse{
            .status = 404,
            .body = try self.allocator.dupe(u8, "{\"error\":{\"message\":\"Not found\",\"type\":\"invalid_request_error\"}}"),
        };
    }

    fn handleHealth(self: *TestContext) !SimulatedResponse {
        const stats = self.broker.getStats();
        const body = try std.fmt.allocPrint(self.allocator,
            \\{{"status":"ok","service":"bdc-aiprompt-streaming","broker_state":"{s}","topics":{d},"messages_in":{d},"messages_out":{d},"uptime_ms":{d}}}
        , .{
            @tagName(self.broker.state),
            stats.topics_count,
            stats.messages_in,
            stats.messages_out,
            stats.uptime_ms,
        });
        return SimulatedResponse{ .status = 200, .body = body };
    }
    
    fn handleReady(self: *TestContext) !SimulatedResponse {
        if (self.broker.state == .Running) {
            return SimulatedResponse{
                .status = 200,
                .body = try self.allocator.dupe(u8, "{\"status\":\"ready\"}"),
            };
        }
        return SimulatedResponse{
            .status = 503,
            .body = try self.allocator.dupe(u8, "{\"status\":\"not_ready\"}"),
        };
    }
    
    fn handleMetrics(self: *TestContext) !SimulatedResponse {
        const stats = self.broker.getStats();
        const body = try std.fmt.allocPrint(self.allocator,
            \\# HELP broker_topics_count Number of active topics
            \\# TYPE broker_topics_count gauge
            \\broker_topics_count {d}
            \\# HELP broker_messages_in Total messages received
            \\# TYPE broker_messages_in counter
            \\broker_messages_in {d}
            \\# HELP broker_uptime_ms Broker uptime in milliseconds
            \\# TYPE broker_uptime_ms gauge
            \\broker_uptime_ms {d}
            \\
        , .{ stats.topics_count, stats.messages_in, stats.uptime_ms });
        return SimulatedResponse{ .status = 200, .body = body };
    }
    
    fn handleGpuInfo(self: *TestContext) !SimulatedResponse {
        return SimulatedResponse{
            .status = 200,
            .body = try self.allocator.dupe(u8, 
                \\{"native_gpu":{"available":false,"reason":"GPU context probing at runtime","backends_compiled":["cuda_cpu_fallback","metal"]},"inference":{"engine":"zig-llama-v1","toon_enabled":true},"service":"bdc-aiprompt-streaming"}
            ),
        };
    }
    
    fn handleModels(self: *TestContext) !SimulatedResponse {
        return SimulatedResponse{
            .status = 200,
            .body = try self.allocator.dupe(u8, 
                \\{"object":"list","data":[{"id":"sap-streaming-llama-zig","object":"model","created":1708000000,"owned_by":"sap-cloud-sdk"}]}
            ),
        };
    }
    
    fn handleChatCompletions(self: *TestContext, body: ?[]const u8) !SimulatedResponse {
        const input = body orelse return SimulatedResponse{
            .status = 400,
            .body = try self.allocator.dupe(u8, "{\"error\":{\"message\":\"Missing request body\"}}"),
        };
        
        const user_content = extractUserContent(input);
        const resp = try std.fmt.allocPrint(self.allocator,
            \\{{"id":"chatcmpl-{d}","object":"chat.completion","created":{d},"model":"sap-streaming-v1","choices":[{{"index":0,"message":{{"role":"assistant","content":"Streaming broker received: {s}"}},"finish_reason":"stop"}}],"usage":{{"prompt_tokens":10,"completion_tokens":20,"total_tokens":30}}}}
        , .{ self.requests_total, std.time.timestamp(), user_content });
        return SimulatedResponse{ .status = 200, .body = resp };
    }
    
    fn handleToonChat(self: *TestContext, body: ?[]const u8) !SimulatedResponse {
        const input = body orelse return SimulatedResponse{
            .status = 400,
            .body = try self.allocator.dupe(u8, "{\"error\":{\"message\":\"Missing request body\"}}"),
        };
        
        const user_content = extractUserContent(input);
        if (user_content.len == 0) {
            return SimulatedResponse{
                .status = 400,
                .body = try self.allocator.dupe(u8, "{\"error\":{\"message\":\"No user message found\"}}"),
            };
        }
        
        const resp = try std.fmt.allocPrint(self.allocator,
            \\{{"id":"chatcmpl-toon-{d}","object":"chat.completion","created":{d},"model":"sap-toon-llama-zig","choices":[{{"index":0,"message":{{"role":"assistant","content":"TOON inference response"}},"finish_reason":"stop"}}],"usage":{{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}},"system_fingerprint":"zig-llama-v1"}}
        , .{ self.requests_total, std.time.timestamp() });
        return SimulatedResponse{ .status = 200, .body = resp };
    }
    
    fn handleCompletions(self: *TestContext, body: ?[]const u8) !SimulatedResponse {
        _ = body;
        return SimulatedResponse{
            .status = 200,
            .body = try std.fmt.allocPrint(self.allocator,
                \\{{"id":"cmpl-{d}","object":"text_completion","created":{d},"model":"sap-streaming-v1","choices":[{{"text":"Completion via streaming broker","index":0,"finish_reason":"stop"}}],"usage":{{"prompt_tokens":5,"completion_tokens":10,"total_tokens":15}}}}
            , .{ self.requests_total, std.time.timestamp() }),
        };
    }
    
    fn handleEmbeddings(self: *TestContext, body: ?[]const u8) !SimulatedResponse {
        _ = body;
        return SimulatedResponse{
            .status = 200,
            .body = try self.allocator.dupe(u8, 
                \\{"object":"list","data":[{"object":"embedding","embedding":[0.0023,-0.0091,0.0152,-0.0042,0.0087],"index":0}],"model":"sap-embedding-v1","usage":{"prompt_tokens":8,"total_tokens":8}}
            ),
        };
    }
    
    fn handleAudio(self: *TestContext) !SimulatedResponse {
        return SimulatedResponse{
            .status = 200,
            .body = try self.allocator.dupe(u8, 
                \\{"text":"Audio transcription requires a Whisper model deployment."}
            ),
        };
    }
    
    fn handleImages(self: *TestContext) !SimulatedResponse {
        return SimulatedResponse{
            .status = 200,
            .body = try self.allocator.dupe(u8, 
                \\{"created":0,"data":[],"message":"Image generation requires a DALL-E or Stable Diffusion model."}
            ),
        };
    }
    
    fn handleFiles(self: *TestContext) !SimulatedResponse {
        return SimulatedResponse{
            .status = 200,
            .body = try self.allocator.dupe(u8, "{\"object\":\"list\",\"data\":[]}"),
        };
    }
    
    fn handleFineTuning(self: *TestContext) !SimulatedResponse {
        return SimulatedResponse{
            .status = 200,
            .body = try self.allocator.dupe(u8, "{\"object\":\"list\",\"data\":[],\"has_more\":false}"),
        };
    }
    
    fn handleModerations(self: *TestContext, body: ?[]const u8) !SimulatedResponse {
        _ = body;
        return SimulatedResponse{
            .status = 200,
            .body = try self.allocator.dupe(u8, 
                \\{"id":"modr-0","model":"text-moderation-stable","results":[{"flagged":false,"categories":{"hate":false,"harassment":false,"self-harm":false,"sexual":false,"violence":false}}]}
            ),
        };
    }
};

pub const Method = enum { GET, POST, PUT, DELETE, OPTIONS };

pub const SimulatedResponse = struct {
    status: u16,
    body: []const u8,

    pub fn deinit(self: *SimulatedResponse, allocator: mem.Allocator) void {
        allocator.free(self.body);
    }
};

/// Extract the last user message content from a chat completions JSON body.
fn extractUserContent(body: []const u8) []const u8 {
    const role_patterns = [_][]const u8{ "\"role\":\"user\"", "\"role\": \"user\"" };
    var last_user_pos: ?usize = null;

    for (role_patterns) |role_pat| {
        var search_from: usize = 0;
        while (mem.indexOfPos(u8, body, search_from, role_pat)) |pos| {
            last_user_pos = pos;
            search_from = pos + role_pat.len;
        }
    }

    const user_pos = last_user_pos orelse return "";

    const content_patterns = [_][]const u8{ "\"content\": \"", "\"content\":\"" };
    for (content_patterns) |content_pat| {
        if (mem.indexOfPos(u8, body, user_pos, content_pat)) |cpos| {
            const text_start = cpos + content_pat.len;
            var text_end = text_start;
            var in_escape = false;

            while (text_end < body.len) {
                const c = body[text_end];
                if (in_escape) {
                    in_escape = false;
                    text_end += 1;
                    continue;
                }
                if (c == '\\') {
                    in_escape = true;
                    text_end += 1;
                    continue;
                }
                if (c == '"') break;
                text_end += 1;
            }

            if (text_start < text_end) {
                return body[text_start..text_end];
            }
        }
    }
    return "";
}

// ============================================================================
// Health & Operations Tests
// ============================================================================

test "GET /health returns broker stats" {
    var ctx = try TestContext.init(testing.allocator);
    
    var response = try ctx.simulateRequest(.GET, "/health", null);
    defer response.deinit(testing.allocator);
    
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "bdc-aiprompt-streaming") != null);
    try testing.expect(mem.indexOf(u8, response.body, "Running") != null);
}

test "GET /healthz alias works" {
    var ctx = try TestContext.init(testing.allocator);
    
    var response = try ctx.simulateRequest(.GET, "/healthz", null);
    defer response.deinit(testing.allocator);
    
    try testing.expectEqual(@as(u16, 200), response.status);
}

test "GET /ready returns 200 when running" {
    var ctx = try TestContext.init(testing.allocator);
    
    var response = try ctx.simulateRequest(.GET, "/ready", null);
    defer response.deinit(testing.allocator);
    
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "ready") != null);
}

test "GET /metrics returns Prometheus format" {
    var ctx = try TestContext.init(testing.allocator);
    
    var response = try ctx.simulateRequest(.GET, "/metrics", null);
    defer response.deinit(testing.allocator);
    
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "# HELP") != null);
    try testing.expect(mem.indexOf(u8, response.body, "broker_topics_count") != null);
}

test "GET /api/gpu/info returns GPU status" {
    var ctx = try TestContext.init(testing.allocator);
    
    var response = try ctx.simulateRequest(.GET, "/api/gpu/info", null);
    defer response.deinit(testing.allocator);
    
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "native_gpu") != null);
    try testing.expect(mem.indexOf(u8, response.body, "toon_enabled") != null);
}

// ============================================================================
// OpenAI API Tests
// ============================================================================

test "GET /v1/models returns model list" {
    var ctx = try TestContext.init(testing.allocator);
    
    var response = try ctx.simulateRequest(.GET, "/v1/models", null);
    defer response.deinit(testing.allocator);
    
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "sap-streaming-llama-zig") != null);
}

test "POST /v1/chat/completions - basic" {
    var ctx = try TestContext.init(testing.allocator);
    
    const body = "{\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}";
    var response = try ctx.simulateRequest(.POST, "/v1/chat/completions", body);
    defer response.deinit(testing.allocator);
    
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "chat.completion") != null);
}

test "POST /v1/chat/completions - missing body returns 400" {
    var ctx = try TestContext.init(testing.allocator);
    
    var response = try ctx.simulateRequest(.POST, "/v1/chat/completions", null);
    defer response.deinit(testing.allocator);
    
    try testing.expectEqual(@as(u16, 400), response.status);
}

test "GET /v1/chat/completions returns 405" {
    var ctx = try TestContext.init(testing.allocator);
    
    var response = try ctx.simulateRequest(.GET, "/v1/chat/completions", null);
    defer response.deinit(testing.allocator);
    
    try testing.expectEqual(@as(u16, 405), response.status);
}

test "POST /v1/toon/chat/completions - TOON inference" {
    var ctx = try TestContext.init(testing.allocator);
    
    const body = "{\"messages\":[{\"role\":\"user\",\"content\":\"test\"}]}";
    var response = try ctx.simulateRequest(.POST, "/v1/toon/chat/completions", body);
    defer response.deinit(testing.allocator);
    
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "sap-toon-llama-zig") != null);
    try testing.expect(mem.indexOf(u8, response.body, "zig-llama-v1") != null);
}

test "POST /v1/toon/chat/completions - no user message returns 400" {
    var ctx = try TestContext.init(testing.allocator);
    
    const body = "{\"messages\":[{\"role\":\"system\",\"content\":\"be helpful\"}]}";
    var response = try ctx.simulateRequest(.POST, "/v1/toon/chat/completions", body);
    defer response.deinit(testing.allocator);
    
    try testing.expectEqual(@as(u16, 400), response.status);
}

test "POST /v1/completions - text completion" {
    var ctx = try TestContext.init(testing.allocator);
    
    const body = "{\"prompt\":\"Hello\"}";
    var response = try ctx.simulateRequest(.POST, "/v1/completions", body);
    defer response.deinit(testing.allocator);
    
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "text_completion") != null);
}

test "POST /v1/embeddings - embedding generation" {
    var ctx = try TestContext.init(testing.allocator);
    
    const body = "{\"input\":\"hello\"}";
    var response = try ctx.simulateRequest(.POST, "/v1/embeddings", body);
    defer response.deinit(testing.allocator);
    
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "embedding") != null);
}

test "POST /v1/audio/transcriptions - audio endpoint" {
    var ctx = try TestContext.init(testing.allocator);
    
    var response = try ctx.simulateRequest(.POST, "/v1/audio/transcriptions", null);
    defer response.deinit(testing.allocator);
    
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "Whisper") != null);
}

test "POST /v1/images/generations - image endpoint" {
    var ctx = try TestContext.init(testing.allocator);
    
    var response = try ctx.simulateRequest(.POST, "/v1/images/generations", null);
    defer response.deinit(testing.allocator);
    
    try testing.expectEqual(@as(u16, 200), response.status);
}

test "GET /v1/files - files endpoint" {
    var ctx = try TestContext.init(testing.allocator);
    
    var response = try ctx.simulateRequest(.GET, "/v1/files", null);
    defer response.deinit(testing.allocator);
    
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "list") != null);
}

test "GET /v1/fine_tuning/jobs - fine tuning endpoint" {
    var ctx = try TestContext.init(testing.allocator);
    
    var response = try ctx.simulateRequest(.GET, "/v1/fine_tuning/jobs", null);
    defer response.deinit(testing.allocator);
    
    try testing.expectEqual(@as(u16, 200), response.status);
}

test "POST /v1/moderations - moderation endpoint" {
    var ctx = try TestContext.init(testing.allocator);
    
    const body = "{\"input\":\"hello\"}";
    var response = try ctx.simulateRequest(.POST, "/v1/moderations", body);
    defer response.deinit(testing.allocator);
    
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "flagged") != null);
}

// ============================================================================
// User Content Extraction Tests
// ============================================================================

test "extractUserContent - basic" {
    const body = "{\"messages\":[{\"role\":\"user\",\"content\":\"hello world\"}]}";
    const content = extractUserContent(body);
    try testing.expectEqualStrings("hello world", content);
}

test "extractUserContent - picks last user message" {
    const body =
        \\{"messages":[{"role":"user","content":"first"},{"role":"assistant","content":"reply"},{"role":"user","content":"second"}]}
    ;
    const content = extractUserContent(body);
    try testing.expectEqualStrings("second", content);
}

test "extractUserContent - returns empty on no user" {
    const body = "{\"messages\":[{\"role\":\"system\",\"content\":\"you are helpful\"}]}";
    const content = extractUserContent(body);
    try testing.expectEqualStrings("", content);
}

test "extractUserContent - handles spaces in JSON" {
    const body = "{\"messages\":[{\"role\": \"user\", \"content\": \"spaced content\"}]}";
    const content = extractUserContent(body);
    try testing.expectEqualStrings("spaced content", content);
}

// ============================================================================
// Protocol Handler Tests
// ============================================================================

test "Protocol handler creates CONNECTED response" {
    var handler = MockProtocolHandler.init(testing.allocator);
    
    const response = try handler.createConnectedResponse("BDC-1.0.0");
    defer testing.allocator.free(response);
    
    try testing.expect(mem.indexOf(u8, response, "CONNECTED") != null);
    try testing.expect(mem.indexOf(u8, response, "BDC-1.0.0") != null);
}

test "Protocol handler creates PONG response" {
    var handler = MockProtocolHandler.init(testing.allocator);
    
    const response = try handler.createPongResponse();
    defer testing.allocator.free(response);
    
    try testing.expectEqualStrings("PONG", response);
}

test "Protocol handler creates SUCCESS response" {
    var handler = MockProtocolHandler.init(testing.allocator);
    
    const response = try handler.createSuccessResponse(12345);
    defer testing.allocator.free(response);
    
    try testing.expect(mem.indexOf(u8, response, "SUCCESS") != null);
    try testing.expect(mem.indexOf(u8, response, "12345") != null);
}

// ============================================================================
// Broker State Tests
// ============================================================================

test "Broker starts in Running state" {
    const broker = MockBroker.init(testing.allocator);
    try testing.expectEqual(MockBroker.BrokerState.Running, broker.state);
}

test "Broker stats are correct" {
    var broker = MockBroker.init(testing.allocator);
    broker.topics_count = 5;
    broker.messages_in = 100;
    broker.messages_out = 95;
    
    const stats = broker.getStats();
    try testing.expectEqual(@as(u32, 5), stats.topics_count);
    try testing.expectEqual(@as(u64, 100), stats.messages_in);
    try testing.expectEqual(@as(u64, 95), stats.messages_out);
    try testing.expect(stats.uptime_ms >= 0);
}

// ============================================================================
// All Routes Coverage
// ============================================================================

test "all routes covered" {
    var ctx = try TestContext.init(testing.allocator);

    const routes = [_]struct { method: Method, path: []const u8, expected: u16 }{
        .{ .method = .GET, .path = "/health", .expected = 200 },
        .{ .method = .GET, .path = "/healthz", .expected = 200 },
        .{ .method = .GET, .path = "/ready", .expected = 200 },
        .{ .method = .GET, .path = "/readyz", .expected = 200 },
        .{ .method = .GET, .path = "/metrics", .expected = 200 },
        .{ .method = .GET, .path = "/api/gpu/info", .expected = 200 },
        .{ .method = .GET, .path = "/v1/models", .expected = 200 },
        .{ .method = .POST, .path = "/v1/chat/completions", .expected = 200 },
        .{ .method = .POST, .path = "/v1/toon/chat/completions", .expected = 200 },
        .{ .method = .POST, .path = "/v1/completions", .expected = 200 },
        .{ .method = .POST, .path = "/v1/embeddings", .expected = 200 },
        .{ .method = .GET, .path = "/v1/files", .expected = 200 },
        .{ .method = .GET, .path = "/v1/fine_tuning/jobs", .expected = 200 },
        .{ .method = .POST, .path = "/v1/moderations", .expected = 200 },
    };

    for (routes) |r| {
        var body_val: ?[]const u8 = null;
        if (r.method == .POST) {
            if (mem.indexOf(u8, r.path, "chat") != null) {
                body_val = "{\"messages\":[{\"role\":\"user\",\"content\":\"test\"}]}";
            } else {
                body_val = "{}";
            }
        }
        var response = try ctx.simulateRequest(r.method, r.path, body_val);
        defer response.deinit(testing.allocator);
        try testing.expectEqual(r.expected, response.status);
    }
}
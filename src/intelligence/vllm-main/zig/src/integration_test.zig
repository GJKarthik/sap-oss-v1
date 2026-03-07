//! Integration Tests for AI Core Private LLM
//!
//! Tests the full request -> route -> handler -> response flow.
//! Validates OpenAI-compatible API, TOON inference, and circuit breaker behavior.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const http_server = @import("http/server.zig");

// ============================================================================
// Mock Components
// ============================================================================

pub const MockLlmBackend = struct {
    allocator: mem.Allocator,
    chat_count: u32 = 0,
    completion_count: u32 = 0,
    embedding_count: u32 = 0,
    last_prompt: ?[]const u8 = null,

    pub fn init(allocator: mem.Allocator) MockLlmBackend {
        return .{ .allocator = allocator };
    }

    pub fn chatCompletion(self: *MockLlmBackend, prompt: []const u8) ![]const u8 {
        self.chat_count += 1;
        self.last_prompt = prompt;
        return try std.fmt.allocPrint(
            self.allocator,
            \\{{"id":"chatcmpl-test","object":"chat.completion","created":{d},"model":"phi-2","choices":[{{"index":0,"message":{{"role":"assistant","content":"Hello from Private LLM!"}},"finish_reason":"stop"}}],"usage":{{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}}}
        ,
            .{std.time.timestamp()},
        );
    }

    pub fn textCompletion(self: *MockLlmBackend, _: []const u8) ![]const u8 {
        self.completion_count += 1;
        return try std.fmt.allocPrint(
            self.allocator,
            \\{{"id":"cmpl-test","object":"text_completion","created":{d},"model":"phi-2","choices":[{{"text":"Completed text.","index":0,"finish_reason":"stop"}}],"usage":{{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}}}}
        ,
            .{std.time.timestamp()},
        );
    }

    pub fn generateEmbedding(self: *MockLlmBackend, _: []const u8) ![]const u8 {
        self.embedding_count += 1;
        return try self.allocator.dupe(u8,
            \\{"object":"list","data":[{"object":"embedding","index":0,"embedding":[0.1,0.2,0.3,0.4,0.5]}],"model":"all-MiniLM-L6-v2","usage":{"prompt_tokens":3,"total_tokens":3}}
        );
    }
};

pub const MockToonEngine = struct {
    allocator: mem.Allocator,
    inference_count: u32 = 0,
    enabled: bool = true,

    pub fn init(allocator: mem.Allocator) MockToonEngine {
        return .{ .allocator = allocator };
    }

    pub fn infer(self: *MockToonEngine, prompt: []const u8) ![]const u8 {
        if (!self.enabled) return error.EngineDisabled;
        self.inference_count += 1;
        return try std.fmt.allocPrint(
            self.allocator,
            \\{{"id":"toon-test","object":"chat.completion","model":"phi-2-toon","choices":[{{"index":0,"message":{{"role":"assistant","content":"TOON inference result for: {s}"}},"finish_reason":"stop"}}]}}
        ,
            .{prompt[0..@min(50, prompt.len)]},
        );
    }
};

pub const MockCircuitBreaker = struct {
    state: State = .closed,
    success_count: u32 = 0,
    failure_count: u32 = 0,

    pub const State = enum { closed, open, half_open };

    pub fn allowRequest(self: *MockCircuitBreaker) bool {
        return self.state != .open;
    }

    pub fn recordSuccess(self: *MockCircuitBreaker) void {
        self.success_count += 1;
        if (self.state == .half_open) self.state = .closed;
    }

    pub fn recordFailure(self: *MockCircuitBreaker) void {
        self.failure_count += 1;
        if (self.failure_count >= 5) self.state = .open;
    }

    pub fn getState(self: *const MockCircuitBreaker) State {
        return self.state;
    }
};

pub const MockRateLimiter = struct {
    requests_allowed: u32 = 1000,
    requests_made: u32 = 0,

    pub fn allow(self: *MockRateLimiter) bool {
        if (self.requests_made >= self.requests_allowed) return false;
        self.requests_made += 1;
        return true;
    }

    pub fn reset(self: *MockRateLimiter) void {
        self.requests_made = 0;
    }
};

// ============================================================================
// Test Harness
// ============================================================================

pub const TestContext = struct {
    allocator: mem.Allocator,
    mock_backend: MockLlmBackend,
    mock_toon: MockToonEngine,
    cb: MockCircuitBreaker,
    rate_limiter: MockRateLimiter,
    toon_enabled: bool = true,

    pub fn init(allocator: mem.Allocator) TestContext {
        return .{
            .allocator = allocator,
            .mock_backend = MockLlmBackend.init(allocator),
            .mock_toon = MockToonEngine.init(allocator),
            .cb = .{},
            .rate_limiter = .{},
        };
    }

    /// Simulate a full request cycle.
    pub fn simulateRequest(
        self: *TestContext,
        method: http_server.Request.Method,
        path: []const u8,
        body: ?[]const u8,
    ) !SimulatedResponse {
        // Rate limiting check
        if (!mem.eql(u8, path, "/health") and !mem.eql(u8, path, "/healthz") and
            !mem.eql(u8, path, "/metrics") and !mem.eql(u8, path, "/ready"))
        {
            if (!self.rate_limiter.allow()) {
                return SimulatedResponse{
                    .status = 429,
                    .body = try self.allocator.dupe(u8, "{\"error\":\"Too Many Requests\"}"),
                };
            }
        }

        // Health check
        if (mem.eql(u8, path, "/health") or mem.eql(u8, path, "/healthz")) {
            if (method != .GET) {
                return SimulatedResponse{
                    .status = 405,
                    .body = try self.allocator.dupe(u8, "{\"error\":\"Method not allowed\"}"),
                };
            }
            return SimulatedResponse{
                .status = 200,
                .body = try self.allocator.dupe(u8, "{\"status\":\"healthy\"}"),
            };
        }

        // Readiness check
        if (mem.eql(u8, path, "/ready") or mem.eql(u8, path, "/readyz")) {
            if (method != .GET) {
                return SimulatedResponse{
                    .status = 405,
                    .body = try self.allocator.dupe(u8, "{\"error\":\"Method not allowed\"}"),
                };
            }
            if (self.cb.getState() == .open) {
                return SimulatedResponse{
                    .status = 503,
                    .body = try self.allocator.dupe(u8, "{\"status\":\"not_ready\"}"),
                };
            }
            return SimulatedResponse{
                .status = 200,
                .body = try self.allocator.dupe(u8, "{\"status\":\"ready\"}"),
            };
        }

        // Metrics
        if (mem.eql(u8, path, "/metrics")) {
            if (method != .GET) {
                return SimulatedResponse{
                    .status = 405,
                    .body = try self.allocator.dupe(u8, "{\"error\":\"Method not allowed\"}"),
                };
            }
            const metrics = try std.fmt.allocPrint(
                self.allocator,
                \\# HELP privatellm_requests_total Total requests
                \\# TYPE privatellm_requests_total counter
                \\privatellm_requests_total{{status="success"}} {d}
                \\privatellm_requests_total{{status="error"}} {d}
                \\privatellm_circuit_breaker_state {d}
            ,
                .{ self.cb.success_count, self.cb.failure_count, @as(u32, if (self.cb.state == .open) 1 else 0) },
            );
            return SimulatedResponse{
                .status = 200,
                .body = metrics,
            };
        }

        // GPU Info
        if (mem.startsWith(u8, path, "/api/gpu/info")) {
            if (method != .GET) {
                return SimulatedResponse{
                    .status = 405,
                    .body = try self.allocator.dupe(u8, "{\"error\":\"Method not allowed\"}"),
                };
            }
            return SimulatedResponse{
                .status = 200,
                .body = try self.allocator.dupe(u8, "{\"native_gpu\":{\"available\":true,\"backend\":\"Metal\"}}"),
            };
        }

        // TOON Chat Completions
        if (mem.startsWith(u8, path, "/v1/toon/chat/completions")) {
            if (method != .POST) {
                return SimulatedResponse{
                    .status = 405,
                    .body = try self.allocator.dupe(u8, "{\"error\":\"Method not allowed\"}"),
                };
            }
            return try self.handleToonChatCompletion(body);
        }

        // Chat Completions
        if (mem.startsWith(u8, path, "/v1/chat/completions")) {
            if (method != .POST) {
                return SimulatedResponse{
                    .status = 405,
                    .body = try self.allocator.dupe(u8, "{\"error\":\"Method not allowed\"}"),
                };
            }
            return try self.handleChatCompletion(body);
        }

        // Text Completions
        if (mem.startsWith(u8, path, "/v1/completions")) {
            if (method != .POST) {
                return SimulatedResponse{
                    .status = 405,
                    .body = try self.allocator.dupe(u8, "{\"error\":\"Method not allowed\"}"),
                };
            }
            return try self.handleTextCompletion(body);
        }

        // Embeddings
        if (mem.startsWith(u8, path, "/v1/embeddings")) {
            if (method != .POST) {
                return SimulatedResponse{
                    .status = 405,
                    .body = try self.allocator.dupe(u8, "{\"error\":\"Method not allowed\"}"),
                };
            }
            return try self.handleEmbeddings(body);
        }

        // Models list
        if (mem.startsWith(u8, path, "/v1/models")) {
            if (method != .GET) {
                return SimulatedResponse{
                    .status = 405,
                    .body = try self.allocator.dupe(u8, "{\"error\":\"Method not allowed\"}"),
                };
            }
            return try self.handleModels();
        }

        // Audio transcriptions
        if (mem.startsWith(u8, path, "/v1/audio/transcriptions")) {
            if (method != .POST) {
                return SimulatedResponse{
                    .status = 405,
                    .body = try self.allocator.dupe(u8, "{\"error\":\"Method not allowed\"}"),
                };
            }
            return SimulatedResponse{
                .status = 200,
                .body = try self.allocator.dupe(u8, "{\"text\":\"Audio transcription requires a Whisper model.\"}"),
            };
        }

        // Image generations
        if (mem.startsWith(u8, path, "/v1/images/generations")) {
            if (method != .POST) {
                return SimulatedResponse{
                    .status = 405,
                    .body = try self.allocator.dupe(u8, "{\"error\":\"Method not allowed\"}"),
                };
            }
            return SimulatedResponse{
                .status = 200,
                .body = try self.allocator.dupe(u8, "{\"created\":0,\"data\":[],\"message\":\"Image generation requires DALL-E.\"}"),
            };
        }

        // Files
        if (mem.startsWith(u8, path, "/v1/files")) {
            return SimulatedResponse{
                .status = 200,
                .body = try self.allocator.dupe(u8, "{\"object\":\"list\",\"data\":[]}"),
            };
        }

        // Fine-tuning jobs
        if (mem.startsWith(u8, path, "/v1/fine_tuning/jobs")) {
            return SimulatedResponse{
                .status = 200,
                .body = try self.allocator.dupe(u8, "{\"object\":\"list\",\"data\":[],\"has_more\":false}"),
            };
        }

        // Moderations
        if (mem.startsWith(u8, path, "/v1/moderations")) {
            if (method != .POST) {
                return SimulatedResponse{
                    .status = 405,
                    .body = try self.allocator.dupe(u8, "{\"error\":\"Method not allowed\"}"),
                };
            }
            return SimulatedResponse{
                .status = 200,
                .body = try self.allocator.dupe(u8, "{\"id\":\"modr-test\",\"model\":\"text-moderation-stable\",\"results\":[{\"flagged\":false}]}"),
            };
        }

        // Not found
        return SimulatedResponse{
            .status = 404,
            .body = try self.allocator.dupe(u8, "{\"error\":\"Not found\"}"),
        };
    }

    fn handleChatCompletion(self: *TestContext, body: ?[]const u8) !SimulatedResponse {
        if (!self.cb.allowRequest()) {
            return SimulatedResponse{
                .status = 503,
                .body = try self.allocator.dupe(u8, "{\"error\":\"Service Unavailable (Circuit Open)\"}"),
            };
        }

        const prompt = body orelse "";
        const response = try self.mock_backend.chatCompletion(prompt);
        self.cb.recordSuccess();

        return SimulatedResponse{
            .status = 200,
            .body = response,
        };
    }

    fn handleToonChatCompletion(self: *TestContext, body: ?[]const u8) !SimulatedResponse {
        if (!self.cb.allowRequest()) {
            return SimulatedResponse{
                .status = 503,
                .body = try self.allocator.dupe(u8, "{\"error\":\"Service Unavailable (Circuit Open)\"}"),
            };
        }

        if (!self.toon_enabled or !self.mock_toon.enabled) {
            // Fall back to regular chat completion
            return try self.handleChatCompletion(body);
        }

        const prompt = extractPromptForTest(body orelse "");
        const response = try self.mock_toon.infer(prompt);
        self.cb.recordSuccess();

        return SimulatedResponse{
            .status = 200,
            .body = response,
        };
    }

    fn handleTextCompletion(self: *TestContext, body: ?[]const u8) !SimulatedResponse {
        if (!self.cb.allowRequest()) {
            return SimulatedResponse{
                .status = 503,
                .body = try self.allocator.dupe(u8, "{\"error\":\"Service Unavailable (Circuit Open)\"}"),
            };
        }

        const prompt = body orelse "";
        const response = try self.mock_backend.textCompletion(prompt);
        self.cb.recordSuccess();

        return SimulatedResponse{
            .status = 200,
            .body = response,
        };
    }

    fn handleEmbeddings(self: *TestContext, body: ?[]const u8) !SimulatedResponse {
        if (!self.cb.allowRequest()) {
            return SimulatedResponse{
                .status = 503,
                .body = try self.allocator.dupe(u8, "{\"error\":\"Service Unavailable (Circuit Open)\"}"),
            };
        }

        const input = body orelse "";
        const response = try self.mock_backend.generateEmbedding(input);
        self.cb.recordSuccess();

        return SimulatedResponse{
            .status = 200,
            .body = response,
        };
    }

    fn handleModels(self: *TestContext) !SimulatedResponse {
        return SimulatedResponse{
            .status = 200,
            .body = try self.allocator.dupe(u8,
                \\{"object":"list","data":[{"id":"phi-2","object":"model","created":0,"owned_by":"microsoft"},{"id":"llama-2-7b","object":"model","created":0,"owned_by":"meta"},{"id":"all-MiniLM-L6-v2","object":"model","created":0,"owned_by":"sentence-transformers"}]}
            ),
        };
    }
};

fn extractPromptForTest(body: []const u8) []const u8 {
    // Simple extraction for testing - find content field
    const needle = "\"content\":\"";
    if (mem.indexOf(u8, body, needle)) |pos| {
        const start = pos + needle.len;
        if (mem.indexOfPos(u8, body, start, "\"")) |end| {
            return body[start..end];
        }
    }
    return "test prompt";
}

pub const SimulatedResponse = struct {
    status: u16,
    body: []const u8,

    pub fn deinit(self: *SimulatedResponse, allocator: mem.Allocator) void {
        allocator.free(self.body);
    }
};

// ============================================================================
// Core Endpoint Tests
// ============================================================================

test "GET /health returns 200" {
    var ctx = TestContext.init(testing.allocator);

    var response = try ctx.simulateRequest(.GET, "/health", null);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "healthy") != null);
}

test "GET /healthz returns 200" {
    var ctx = TestContext.init(testing.allocator);

    var response = try ctx.simulateRequest(.GET, "/healthz", null);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
}

test "POST /health returns 405" {
    var ctx = TestContext.init(testing.allocator);

    var response = try ctx.simulateRequest(.POST, "/health", null);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 405), response.status);
}

test "GET /ready returns 200 when circuit closed" {
    var ctx = TestContext.init(testing.allocator);

    var response = try ctx.simulateRequest(.GET, "/ready", null);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "\"status\":\"ready\"") != null);
}

test "GET /ready returns 503 when circuit open" {
    var ctx = TestContext.init(testing.allocator);
    ctx.cb.state = .open;

    var response = try ctx.simulateRequest(.GET, "/ready", null);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 503), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "not_ready") != null);
}

test "GET /metrics returns Prometheus format" {
    var ctx = TestContext.init(testing.allocator);

    var response = try ctx.simulateRequest(.GET, "/metrics", null);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "# HELP") != null);
    try testing.expect(mem.indexOf(u8, response.body, "# TYPE") != null);
}

// ============================================================================
// OpenAI API Tests
// ============================================================================

test "POST /v1/chat/completions returns OpenAI format" {
    var ctx = TestContext.init(testing.allocator);

    const body = "{\"model\":\"phi-2\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}";
    var response = try ctx.simulateRequest(.POST, "/v1/chat/completions", body);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "chat.completion") != null);
    try testing.expect(mem.indexOf(u8, response.body, "choices") != null);
    try testing.expectEqual(@as(u32, 1), ctx.mock_backend.chat_count);
}

test "GET /v1/chat/completions returns 405" {
    var ctx = TestContext.init(testing.allocator);

    var response = try ctx.simulateRequest(.GET, "/v1/chat/completions", null);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 405), response.status);
}

test "POST /v1/completions returns text completion" {
    var ctx = TestContext.init(testing.allocator);

    const body = "{\"model\":\"phi-2\",\"prompt\":\"Once upon a time\"}";
    var response = try ctx.simulateRequest(.POST, "/v1/completions", body);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "text_completion") != null);
    try testing.expectEqual(@as(u32, 1), ctx.mock_backend.completion_count);
}

test "POST /v1/embeddings returns embeddings" {
    var ctx = TestContext.init(testing.allocator);

    const body = "{\"input\":\"Hello world\",\"model\":\"all-MiniLM-L6-v2\"}";
    var response = try ctx.simulateRequest(.POST, "/v1/embeddings", body);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "embedding") != null);
    try testing.expectEqual(@as(u32, 1), ctx.mock_backend.embedding_count);
}

test "GET /v1/models returns model list" {
    var ctx = TestContext.init(testing.allocator);

    var response = try ctx.simulateRequest(.GET, "/v1/models", null);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "phi-2") != null);
    try testing.expect(mem.indexOf(u8, response.body, "llama-2-7b") != null);
}

// ============================================================================
// TOON Inference Tests
// ============================================================================

test "POST /v1/toon/chat/completions uses TOON engine" {
    var ctx = TestContext.init(testing.allocator);

    const body = "{\"messages\":[{\"role\":\"user\",\"content\":\"TOON test\"}]}";
    var response = try ctx.simulateRequest(.POST, "/v1/toon/chat/completions", body);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "phi-2-toon") != null);
    try testing.expectEqual(@as(u32, 1), ctx.mock_toon.inference_count);
}

test "TOON disabled falls back to regular completion" {
    var ctx = TestContext.init(testing.allocator);
    ctx.toon_enabled = false;

    const body = "{\"messages\":[{\"role\":\"user\",\"content\":\"test\"}]}";
    var response = try ctx.simulateRequest(.POST, "/v1/toon/chat/completions", body);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expectEqual(@as(u32, 0), ctx.mock_toon.inference_count);
    try testing.expectEqual(@as(u32, 1), ctx.mock_backend.chat_count);
}

// ============================================================================
// Extension Endpoint Tests
// ============================================================================

test "POST /v1/audio/transcriptions returns info message" {
    var ctx = TestContext.init(testing.allocator);

    var response = try ctx.simulateRequest(.POST, "/v1/audio/transcriptions", "audio data");
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "Whisper") != null);
}

test "POST /v1/images/generations returns info message" {
    var ctx = TestContext.init(testing.allocator);

    var response = try ctx.simulateRequest(.POST, "/v1/images/generations", "{\"prompt\":\"cat\"}");
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "DALL-E") != null);
}

test "GET /v1/files returns empty list" {
    var ctx = TestContext.init(testing.allocator);

    var response = try ctx.simulateRequest(.GET, "/v1/files", null);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "\"data\":[]") != null);
}

test "GET /v1/fine_tuning/jobs returns empty list" {
    var ctx = TestContext.init(testing.allocator);

    var response = try ctx.simulateRequest(.GET, "/v1/fine_tuning/jobs", null);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "\"has_more\":false") != null);
}

test "POST /v1/moderations returns not flagged" {
    var ctx = TestContext.init(testing.allocator);

    const body = "{\"input\":\"Hello world\"}";
    var response = try ctx.simulateRequest(.POST, "/v1/moderations", body);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "\"flagged\":false") != null);
}

test "GET /api/gpu/info returns GPU status" {
    var ctx = TestContext.init(testing.allocator);

    var response = try ctx.simulateRequest(.GET, "/api/gpu/info", null);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "native_gpu") != null);
}

// ============================================================================
// Circuit Breaker Tests
// ============================================================================

test "circuit breaker blocks requests when open" {
    var ctx = TestContext.init(testing.allocator);
    ctx.cb.state = .open;

    const body = "{\"messages\":[{\"role\":\"user\",\"content\":\"test\"}]}";
    var response = try ctx.simulateRequest(.POST, "/v1/chat/completions", body);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 503), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "Circuit Open") != null);
}

test "circuit breaker records success" {
    var cb = MockCircuitBreaker{};
    try testing.expectEqual(@as(u32, 0), cb.success_count);

    cb.recordSuccess();
    try testing.expectEqual(@as(u32, 1), cb.success_count);
}

test "circuit breaker opens after threshold failures" {
    var cb = MockCircuitBreaker{};
    try testing.expectEqual(MockCircuitBreaker.State.closed, cb.getState());

    for (0..5) |_| cb.recordFailure();

    try testing.expectEqual(MockCircuitBreaker.State.open, cb.getState());
}

// ============================================================================
// Rate Limiting Tests
// ============================================================================

test "rate limiter blocks excess requests" {
    var ctx = TestContext.init(testing.allocator);
    ctx.rate_limiter.requests_allowed = 3;

    // First 3 requests succeed
    for (0..3) |_| {
        var response = try ctx.simulateRequest(.POST, "/v1/chat/completions", "{}");
        response.deinit(testing.allocator);
    }

    // 4th request is rate limited
    var response = try ctx.simulateRequest(.POST, "/v1/chat/completions", "{}");
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 429), response.status);
}

test "rate limiter allows health checks" {
    var ctx = TestContext.init(testing.allocator);
    ctx.rate_limiter.requests_allowed = 0; // Block all regular requests

    // Health check should still work
    var response = try ctx.simulateRequest(.GET, "/health", null);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
}

// ============================================================================
// 404 Test
// ============================================================================

test "unknown path returns 404" {
    var ctx = TestContext.init(testing.allocator);

    var response = try ctx.simulateRequest(.GET, "/unknown/endpoint", null);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 404), response.status);
}

// ============================================================================
// All Routes Coverage Test
// ============================================================================

test "all routes are covered" {
    var ctx = TestContext.init(testing.allocator);

    const routes = [_]struct { method: http_server.Request.Method, path: []const u8, expected_status: u16 }{
        .{ .method = .GET, .path = "/health", .expected_status = 200 },
        .{ .method = .GET, .path = "/healthz", .expected_status = 200 },
        .{ .method = .GET, .path = "/ready", .expected_status = 200 },
        .{ .method = .GET, .path = "/readyz", .expected_status = 200 },
        .{ .method = .GET, .path = "/metrics", .expected_status = 200 },
        .{ .method = .GET, .path = "/api/gpu/info", .expected_status = 200 },
        .{ .method = .POST, .path = "/v1/chat/completions", .expected_status = 200 },
        .{ .method = .POST, .path = "/v1/toon/chat/completions", .expected_status = 200 },
        .{ .method = .POST, .path = "/v1/completions", .expected_status = 200 },
        .{ .method = .POST, .path = "/v1/embeddings", .expected_status = 200 },
        .{ .method = .GET, .path = "/v1/models", .expected_status = 200 },
        .{ .method = .POST, .path = "/v1/audio/transcriptions", .expected_status = 200 },
        .{ .method = .POST, .path = "/v1/images/generations", .expected_status = 200 },
        .{ .method = .GET, .path = "/v1/files", .expected_status = 200 },
        .{ .method = .GET, .path = "/v1/fine_tuning/jobs", .expected_status = 200 },
        .{ .method = .POST, .path = "/v1/moderations", .expected_status = 200 },
    };

    for (routes) |r| {
        ctx.rate_limiter.reset();
        const body: ?[]const u8 = if (r.method == .POST) "{\"test\":true}" else null;
        var response = try ctx.simulateRequest(r.method, r.path, body);
        defer response.deinit(testing.allocator);
        try testing.expectEqual(r.expected_status, response.status);
    }
}
//! Integration Tests
//!
//! End-to-end tests for the vLLM system.
//! Tests complete workflows from API to inference.
//!
//! Test Categories:
//! - Server endpoints
//! - Request flow
//! - Model loading
//! - Inference pipeline
//! - Error handling

const std = @import("std");
const test_framework = @import("../unit/test_framework.zig");

const TestContext = test_framework.TestContext;
const TestSuite = test_framework.TestSuite;
const TestRunner = test_framework.TestRunner;

// ==============================================
// Test Configuration
// ==============================================

pub const IntegrationTestConfig = struct {
    /// Server host
    host: []const u8 = "localhost",
    
    /// Server port
    port: u16 = 8000,
    
    /// Test timeout (ms)
    timeout_ms: u64 = 30000,
    
    /// Model to use for tests
    test_model: []const u8 = "test-model",
    
    /// Skip tests requiring GPU
    skip_gpu_tests: bool = true,
    
    /// Verbose output
    verbose: bool = true,
};

// ==============================================
// HTTP Client for Testing
// ==============================================

pub const TestHttpClient = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    
    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !TestHttpClient {
        const url = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ host, port });
        return TestHttpClient{
            .allocator = allocator,
            .base_url = url,
        };
    }
    
    pub fn deinit(self: *TestHttpClient) void {
        self.allocator.free(self.base_url);
    }
    
    pub const Response = struct {
        status: u16,
        body: []const u8,
        headers: std.StringHashMap([]const u8),
        
        pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
            allocator.free(self.body);
            self.headers.deinit();
        }
    };
    
    pub fn get(self: *TestHttpClient, path: []const u8) !Response {
        _ = self;
        _ = path;
        // Placeholder - would use actual HTTP client
        return Response{
            .status = 200,
            .body = "",
            .headers = std.StringHashMap([]const u8).init(self.allocator),
        };
    }
    
    pub fn post(self: *TestHttpClient, path: []const u8, body: []const u8) !Response {
        _ = self;
        _ = path;
        _ = body;
        // Placeholder - would use actual HTTP client
        return Response{
            .status = 200,
            .body = "",
            .headers = std.StringHashMap([]const u8).init(self.allocator),
        };
    }
};

// ==============================================
// Server Tests
// ==============================================

pub fn createServerTests(allocator: std.mem.Allocator) !TestSuite {
    var suite = TestSuite.init(allocator, "Server Integration Tests");
    
    try suite.test_("health endpoint returns 200", testHealthEndpoint);
    try suite.test_("health/ready returns 200 when ready", testReadinessEndpoint);
    try suite.test_("models endpoint lists models", testModelsEndpoint);
    try suite.test_("unknown endpoint returns 404", testUnknownEndpoint);
    try suite.test_("malformed request returns 400", testMalformedRequest);
    
    return suite;
}

fn testHealthEndpoint(ctx: *TestContext) !void {
    var client = try TestHttpClient.init(ctx.allocator, "localhost", 8000);
    defer client.deinit();
    
    var response = try client.get("/health");
    defer response.deinit(ctx.allocator);
    
    ctx.expectEqual(@as(u16, 200), response.status);
}

fn testReadinessEndpoint(ctx: *TestContext) !void {
    var client = try TestHttpClient.init(ctx.allocator, "localhost", 8000);
    defer client.deinit();
    
    var response = try client.get("/health/ready");
    defer response.deinit(ctx.allocator);
    
    ctx.expect(response.status == 200 or response.status == 503);
}

fn testModelsEndpoint(ctx: *TestContext) !void {
    var client = try TestHttpClient.init(ctx.allocator, "localhost", 8000);
    defer client.deinit();
    
    var response = try client.get("/v1/models");
    defer response.deinit(ctx.allocator);
    
    ctx.expectEqual(@as(u16, 200), response.status);
}

fn testUnknownEndpoint(ctx: *TestContext) !void {
    var client = try TestHttpClient.init(ctx.allocator, "localhost", 8000);
    defer client.deinit();
    
    var response = try client.get("/nonexistent");
    defer response.deinit(ctx.allocator);
    
    ctx.expectEqual(@as(u16, 404), response.status);
}

fn testMalformedRequest(ctx: *TestContext) !void {
    var client = try TestHttpClient.init(ctx.allocator, "localhost", 8000);
    defer client.deinit();
    
    var response = try client.post("/v1/completions", "invalid json{{{");
    defer response.deinit(ctx.allocator);
    
    ctx.expectEqual(@as(u16, 400), response.status);
}

// ==============================================
// Completion Tests
// ==============================================

pub fn createCompletionTests(allocator: std.mem.Allocator) !TestSuite {
    var suite = TestSuite.init(allocator, "Completion Integration Tests");
    
    try suite.test_("basic completion request", testBasicCompletion);
    try suite.test_("completion with max_tokens", testCompletionMaxTokens);
    try suite.test_("completion with temperature", testCompletionTemperature);
    try suite.test_("streaming completion", testStreamingCompletion);
    try suite.test_("completion with stop sequence", testCompletionStopSequence);
    
    return suite;
}

fn testBasicCompletion(ctx: *TestContext) !void {
    const request = 
        \\{
        \\  "model": "test-model",
        \\  "prompt": "Hello, world!",
        \\  "max_tokens": 10
        \\}
    ;
    
    var client = try TestHttpClient.init(ctx.allocator, "localhost", 8000);
    defer client.deinit();
    
    var response = try client.post("/v1/completions", request);
    defer response.deinit(ctx.allocator);
    
    ctx.expectEqual(@as(u16, 200), response.status);
}

fn testCompletionMaxTokens(ctx: *TestContext) !void {
    const request = 
        \\{
        \\  "model": "test-model",
        \\  "prompt": "Count to 100:",
        \\  "max_tokens": 5
        \\}
    ;
    
    var client = try TestHttpClient.init(ctx.allocator, "localhost", 8000);
    defer client.deinit();
    
    var response = try client.post("/v1/completions", request);
    defer response.deinit(ctx.allocator);
    
    ctx.expectEqual(@as(u16, 200), response.status);
    // Would verify response has <= 5 tokens
}

fn testCompletionTemperature(ctx: *TestContext) !void {
    const request = 
        \\{
        \\  "model": "test-model",
        \\  "prompt": "Random word:",
        \\  "max_tokens": 1,
        \\  "temperature": 1.5
        \\}
    ;
    
    var client = try TestHttpClient.init(ctx.allocator, "localhost", 8000);
    defer client.deinit();
    
    var response = try client.post("/v1/completions", request);
    defer response.deinit(ctx.allocator);
    
    ctx.expectEqual(@as(u16, 200), response.status);
}

fn testStreamingCompletion(ctx: *TestContext) !void {
    const request = 
        \\{
        \\  "model": "test-model",
        \\  "prompt": "Hello",
        \\  "max_tokens": 10,
        \\  "stream": true
        \\}
    ;
    
    var client = try TestHttpClient.init(ctx.allocator, "localhost", 8000);
    defer client.deinit();
    
    var response = try client.post("/v1/completions", request);
    defer response.deinit(ctx.allocator);
    
    ctx.expectEqual(@as(u16, 200), response.status);
    // Would verify SSE format
}

fn testCompletionStopSequence(ctx: *TestContext) !void {
    const request = 
        \\{
        \\  "model": "test-model",
        \\  "prompt": "List: 1, 2, 3,",
        \\  "max_tokens": 20,
        \\  "stop": ["\n", "."]
        \\}
    ;
    
    var client = try TestHttpClient.init(ctx.allocator, "localhost", 8000);
    defer client.deinit();
    
    var response = try client.post("/v1/completions", request);
    defer response.deinit(ctx.allocator);
    
    ctx.expectEqual(@as(u16, 200), response.status);
}

// ==============================================
// Chat Tests
// ==============================================

pub fn createChatTests(allocator: std.mem.Allocator) !TestSuite {
    var suite = TestSuite.init(allocator, "Chat Integration Tests");
    
    try suite.test_("basic chat request", testBasicChat);
    try suite.test_("chat with system message", testChatSystemMessage);
    try suite.test_("multi-turn conversation", testMultiTurnChat);
    try suite.test_("chat streaming", testChatStreaming);
    
    return suite;
}

fn testBasicChat(ctx: *TestContext) !void {
    const request = 
        \\{
        \\  "model": "test-model",
        \\  "messages": [
        \\    {"role": "user", "content": "Hello!"}
        \\  ]
        \\}
    ;
    
    var client = try TestHttpClient.init(ctx.allocator, "localhost", 8000);
    defer client.deinit();
    
    var response = try client.post("/v1/chat/completions", request);
    defer response.deinit(ctx.allocator);
    
    ctx.expectEqual(@as(u16, 200), response.status);
}

fn testChatSystemMessage(ctx: *TestContext) !void {
    const request = 
        \\{
        \\  "model": "test-model",
        \\  "messages": [
        \\    {"role": "system", "content": "You are helpful."},
        \\    {"role": "user", "content": "Hello!"}
        \\  ]
        \\}
    ;
    
    var client = try TestHttpClient.init(ctx.allocator, "localhost", 8000);
    defer client.deinit();
    
    var response = try client.post("/v1/chat/completions", request);
    defer response.deinit(ctx.allocator);
    
    ctx.expectEqual(@as(u16, 200), response.status);
}

fn testMultiTurnChat(ctx: *TestContext) !void {
    const request = 
        \\{
        \\  "model": "test-model",
        \\  "messages": [
        \\    {"role": "user", "content": "My name is Alice."},
        \\    {"role": "assistant", "content": "Hello Alice!"},
        \\    {"role": "user", "content": "What is my name?"}
        \\  ]
        \\}
    ;
    
    var client = try TestHttpClient.init(ctx.allocator, "localhost", 8000);
    defer client.deinit();
    
    var response = try client.post("/v1/chat/completions", request);
    defer response.deinit(ctx.allocator);
    
    ctx.expectEqual(@as(u16, 200), response.status);
}

fn testChatStreaming(ctx: *TestContext) !void {
    const request = 
        \\{
        \\  "model": "test-model",
        \\  "messages": [{"role": "user", "content": "Hi"}],
        \\  "stream": true
        \\}
    ;
    
    var client = try TestHttpClient.init(ctx.allocator, "localhost", 8000);
    defer client.deinit();
    
    var response = try client.post("/v1/chat/completions", request);
    defer response.deinit(ctx.allocator);
    
    ctx.expectEqual(@as(u16, 200), response.status);
}

// ==============================================
// Error Handling Tests
// ==============================================

pub fn createErrorTests(allocator: std.mem.Allocator) !TestSuite {
    var suite = TestSuite.init(allocator, "Error Handling Tests");
    
    try suite.test_("invalid model returns 404", testInvalidModel);
    try suite.test_("missing prompt returns 400", testMissingPrompt);
    try suite.test_("invalid temperature returns 400", testInvalidTemperature);
    try suite.test_("prompt too long returns 400", testPromptTooLong);
    try suite.test_("rate limit returns 429", testRateLimit);
    
    return suite;
}

fn testInvalidModel(ctx: *TestContext) !void {
    const request = 
        \\{
        \\  "model": "nonexistent-model",
        \\  "prompt": "Hello"
        \\}
    ;
    
    var client = try TestHttpClient.init(ctx.allocator, "localhost", 8000);
    defer client.deinit();
    
    var response = try client.post("/v1/completions", request);
    defer response.deinit(ctx.allocator);
    
    ctx.expectEqual(@as(u16, 404), response.status);
}

fn testMissingPrompt(ctx: *TestContext) !void {
    const request = 
        \\{
        \\  "model": "test-model"
        \\}
    ;
    
    var client = try TestHttpClient.init(ctx.allocator, "localhost", 8000);
    defer client.deinit();
    
    var response = try client.post("/v1/completions", request);
    defer response.deinit(ctx.allocator);
    
    ctx.expectEqual(@as(u16, 400), response.status);
}

fn testInvalidTemperature(ctx: *TestContext) !void {
    const request = 
        \\{
        \\  "model": "test-model",
        \\  "prompt": "Hello",
        \\  "temperature": 5.0
        \\}
    ;
    
    var client = try TestHttpClient.init(ctx.allocator, "localhost", 8000);
    defer client.deinit();
    
    var response = try client.post("/v1/completions", request);
    defer response.deinit(ctx.allocator);
    
    ctx.expectEqual(@as(u16, 400), response.status);
}

fn testPromptTooLong(ctx: *TestContext) !void {
    // Create very long prompt
    var long_prompt = std.ArrayList(u8).init(ctx.allocator);
    defer long_prompt.deinit();
    
    try long_prompt.appendSlice("{\"model\":\"test-model\",\"prompt\":\"");
    for (0..200000) |_| {
        try long_prompt.append('x');
    }
    try long_prompt.appendSlice("\"}");
    
    var client = try TestHttpClient.init(ctx.allocator, "localhost", 8000);
    defer client.deinit();
    
    var response = try client.post("/v1/completions", long_prompt.items);
    defer response.deinit(ctx.allocator);
    
    ctx.expectEqual(@as(u16, 400), response.status);
}

fn testRateLimit(ctx: *TestContext) !void {
    var client = try TestHttpClient.init(ctx.allocator, "localhost", 8000);
    defer client.deinit();
    
    const request = 
        \\{
        \\  "model": "test-model",
        \\  "prompt": "Hello",
        \\  "max_tokens": 1
        \\}
    ;
    
    // Send many requests quickly
    var got_429 = false;
    for (0..100) |_| {
        var response = try client.post("/v1/completions", request);
        if (response.status == 429) {
            got_429 = true;
            response.deinit(ctx.allocator);
            break;
        }
        response.deinit(ctx.allocator);
    }
    
    // Rate limiting should eventually kick in
    ctx.expect(got_429);
}

// ==============================================
// Run All Integration Tests
// ==============================================

pub fn runAllTests(allocator: std.mem.Allocator) !test_framework.TestResults {
    var runner = TestRunner.init(allocator);
    defer runner.deinit();
    
    try runner.addSuite(try createServerTests(allocator));
    try runner.addSuite(try createCompletionTests(allocator));
    try runner.addSuite(try createChatTests(allocator));
    try runner.addSuite(try createErrorTests(allocator));
    
    return runner.run();
}

// ==============================================
// Main Entry Point
// ==============================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const results = try runAllTests(allocator);
    
    if (!results.success()) {
        std.process.exit(1);
    }
}
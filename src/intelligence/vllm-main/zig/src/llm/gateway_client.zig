//! LLM Gateway Client
//!
//! HTTP client for calling the central rustshimmy LLM gateway.
//! All 8 services use this to access the single LLM instance running on GPU.
//!
//! Architecture:
//!   [Service 1] ─┐
//!   [Service 2] ─┼──► [rustshimmy LLM Gateway (T4 GPU)] ──► [Response]
//!   [Service N] ─┘

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const http = std.http;

// ============================================================================
// Gateway Configuration
// ============================================================================

pub const GatewayConfig = struct {
    /// Gateway URL (AI Core deployment URL or localhost for dev)
    gateway_url: []const u8 = "http://localhost:8080",
    
    /// API endpoint path
    api_path: []const u8 = "/v1/chat/completions",
    
    /// Request timeout in milliseconds
    timeout_ms: u32 = 30000,
    
    /// Retry count for failed requests
    max_retries: u8 = 3,
    
    /// AI Core resource group
    resource_group: []const u8 = "default",
    
    /// Model to use
    model: []const u8 = "phi-2",
    
    pub fn forAICore(deployment_url: []const u8) GatewayConfig {
        return .{
            .gateway_url = deployment_url,
            .api_path = "/v1/chat/completions",
            .timeout_ms = 30000,
            .max_retries = 3,
        };
    }
    
    pub fn forLocal() GatewayConfig {
        return .{
            .gateway_url = "http://localhost:8080",
            .api_path = "/v1/chat/completions",
            .timeout_ms = 10000,
            .max_retries = 1,
        };
    }
};

// ============================================================================
// Request/Response Types
// ============================================================================

pub const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
};

pub const CompletionRequest = struct {
    model: []const u8 = "phi-2",
    messages: []const ChatMessage,
    max_tokens: u32 = 256,
    temperature: f32 = 0.1,
    top_p: f32 = 0.9,
    stream: bool = false,
};

pub const CompletionResponse = struct {
    id: []const u8,
    model: []const u8,
    choices: []const Choice,
    usage: Usage,
    
    pub const Choice = struct {
        index: u32,
        message: ChatMessage,
        finish_reason: []const u8,
    };
    
    pub const Usage = struct {
        prompt_tokens: u32,
        completion_tokens: u32,
        total_tokens: u32,
    };
};

// ============================================================================
// LLM Gateway Client
// ============================================================================

pub const LLMGatewayClient = struct {
    allocator: Allocator,
    config: GatewayConfig,
    
    // Stats
    total_requests: u64 = 0,
    total_tokens: u64 = 0,
    failed_requests: u64 = 0,
    
    pub fn init(allocator: Allocator, config: GatewayConfig) LLMGatewayClient {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }
    
    /// Send a chat completion request to the LLM gateway
    pub fn complete(self: *LLMGatewayClient, messages: []const ChatMessage) ![]const u8 {
        self.total_requests += 1;
        
        // Build request JSON
        const request_json = try self.buildRequestJson(messages);
        defer self.allocator.free(request_json);
        
        // Make HTTP request with retries
        var retries: u8 = 0;
        while (retries < self.config.max_retries) : (retries += 1) {
            const response = self.makeHttpRequest(request_json) catch |err| {
                std.log.warn("LLM gateway request failed (attempt {}): {}", .{ retries + 1, err });
                continue;
            };
            defer self.allocator.free(response);
            
            // Parse response and extract content
            const content = try self.parseResponse(response);
            return content;
        }
        
        self.failed_requests += 1;
        return error.GatewayRequestFailed;
    }
    
    /// Simple chat completion with single user message
    pub fn chat(self: *LLMGatewayClient, prompt: []const u8) ![]const u8 {
        const messages = &[_]ChatMessage{
            .{ .role = "user", .content = prompt },
        };
        return self.complete(messages);
    }
    
    /// TOON-formatted completion
    pub fn completeToon(self: *LLMGatewayClient, prompt: []const u8) ![]const u8 {
        const system_msg = 
            \\You are a precise assistant. Always respond in TOON format.
            \\TOON rules:
            \\- Use key:value syntax (no JSON)
            \\- Arrays use | separator: items:a|b|c
            \\- No quotes around simple strings
            \\- Booleans: true/false
            \\- Null: ~
        ;
        
        const messages = &[_]ChatMessage{
            .{ .role = "system", .content = system_msg },
            .{ .role = "user", .content = prompt },
        };
        return self.complete(messages);
    }
    
    /// Build request JSON
    fn buildRequestJson(self: *LLMGatewayClient, messages: []const ChatMessage) ![]u8 {
        var json = std.ArrayList(u8){};
        errdefer json.deinit();

        const writer = json.writer();
        
        try writer.writeAll("{\"model\":\"");
        try writeJsonEscaped(writer, self.config.model);
        try writer.writeAll("\",\"messages\":[");
        
        for (messages, 0..) |msg, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"role\":\"");
            try writeJsonEscaped(writer, msg.role);
            try writer.writeAll("\",\"content\":\"");
            try writeJsonEscaped(writer, msg.content);
            try writer.writeAll("\"}");
        }
        
        try writer.writeAll("],\"max_tokens\":256,\"temperature\":0.1}");
        
        return json.toOwnedSlice();
    }
    
    /// Make HTTP POST request
    fn makeHttpRequest(self: *LLMGatewayClient, body: []const u8) ![]const u8 {
        // Build full URL
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{
            self.config.gateway_url,
            self.config.api_path,
        });
        defer self.allocator.free(url);
        
        // Parse URI
        const uri = try std.Uri.parse(url);
        
        // Create HTTP client
        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();
        
        // Create request buffer
        var buf: [4096]u8 = undefined;
        
        // Make request
        var req = try client.open(.POST, uri, .{
            .server_header_buffer = &buf,
        });
        defer req.deinit();
        
        // Set headers
        req.headers.content_type = .{ .override = "application/json" };
        
        // Send request
        try req.send();
        try req.writeAll(body);
        try req.finish();
        
        // Wait for response
        try req.wait();
        
        // Read response body
        const response_body = try req.reader().readAllAlloc(self.allocator, 1024 * 1024);
        
        return response_body;
    }
    
    /// Parse response JSON and extract content
    fn parseResponse(self: *LLMGatewayClient, response: []const u8) ![]const u8 {
        // Simple JSON parsing to extract content
        // Look for "content": "..." pattern
        const content_marker = "\"content\":\"";
        const start = mem.indexOf(u8, response, content_marker) orelse return error.InvalidResponse;
        const content_start = start + content_marker.len;
        
        // Find end of content (closing quote, not escaped)
        var end = content_start;
        var escaped = false;
        while (end < response.len) : (end += 1) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (response[end] == '\\') {
                escaped = true;
                continue;
            }
            if (response[end] == '"') break;
        }
        
        // Unescape content
        const raw_content = response[content_start..end];
        return try self.unescapeJson(raw_content);
    }
    
    /// Unescape JSON string
    fn unescapeJson(self: *LLMGatewayClient, input: []const u8) ![]u8 {
        var output = std.ArrayList(u8){};
        errdefer output.deinit();
        
        var i: usize = 0;
        while (i < input.len) : (i += 1) {
            if (input[i] == '\\' and i + 1 < input.len) {
                i += 1;
                switch (input[i]) {
                    'n' => try output.append('\n'),
                    'r' => try output.append('\r'),
                    't' => try output.append('\t'),
                    '"' => try output.append('"'),
                    '\\' => try output.append('\\'),
                    else => {
                        try output.append('\\');
                        try output.append(input[i]);
                    },
                }
            } else {
                try output.append(input[i]);
            }
        }
        
        return output.toOwnedSlice();
    }
    
    /// Get client stats
    pub fn getStats(self: *LLMGatewayClient) GatewayStats {
        return .{
            .total_requests = self.total_requests,
            .total_tokens = self.total_tokens,
            .failed_requests = self.failed_requests,
            .success_rate = if (self.total_requests > 0)
                @as(f32, @floatFromInt(self.total_requests - self.failed_requests)) / @as(f32, @floatFromInt(self.total_requests)) * 100
            else
                0,
        };
    }
};

pub const GatewayStats = struct {
    total_requests: u64,
    total_tokens: u64,
    failed_requests: u64,
    success_rate: f32,
};

// ============================================================================
// Service-Specific Clients
// ============================================================================

/// Client for embedding generation — calls /v1/embeddings and parses the response.
pub const EmbeddingClient = struct {
    gateway: LLMGatewayClient,
    /// Endpoint path for embeddings (default: /v1/embeddings)
    embed_path: []const u8 = "/v1/embeddings",

    pub fn init(allocator: Allocator, config: GatewayConfig) EmbeddingClient {
        return .{
            .gateway = LLMGatewayClient.init(allocator, config),
        };
    }

    /// Generate an embedding vector for `text` via the gateway's /v1/embeddings endpoint.
    /// Returns a caller-owned []f32 slice. Caller must free with the same allocator.
    pub fn embed(self: *EmbeddingClient, text: []const u8) ![]f32 {
        const allocator = self.gateway.allocator;

        // Build {"model":"...","input":"..."}
        const body = try buildEmbedRequestJson(allocator, self.gateway.config.model, text);
        defer allocator.free(body);

        // POST to /v1/embeddings
        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{
            self.gateway.config.gateway_url,
            self.embed_path,
        });
        defer allocator.free(url);

        const uri = try std.Uri.parse(url);
        var client = http.Client{ .allocator = allocator };
        defer client.deinit();

        var buf: [4096]u8 = undefined;
        var req = try client.open(.POST, uri, .{ .server_header_buffer = &buf });
        defer req.deinit();
        req.headers.content_type = .{ .override = "application/json" };
        try req.send();
        try req.writeAll(body);
        try req.finish();
        try req.wait();

        const response = try req.reader().readAllAlloc(allocator, 4 * 1024 * 1024);
        defer allocator.free(response);

        return parseEmbedResponse(allocator, response);
    }

    /// Build the JSON body for a /v1/embeddings request.
    fn buildEmbedRequestJson(allocator: Allocator, model: []const u8, input: []const u8) ![]u8 {
        var buf = std.ArrayList(u8){};
        errdefer buf.deinit();
        const w = buf.writer();
        try w.writeAll("{\"model\":\"");
        try writeJsonEscaped(w, model);
        try w.writeAll("\",\"input\":\"");
        try writeJsonEscaped(w, input);
        try w.writeAll("\"}");
        return buf.toOwnedSlice();
    }

    /// Parse {"data":[{"embedding":[f32,...]},...]} and return data[0].embedding.
    fn parseEmbedResponse(allocator: Allocator, response: []const u8) ![]f32 {
        // Locate "embedding":[ — works for both /v1/embeddings and custom formats
        const marker = "\"embedding\":[";
        const start_pos = mem.indexOf(u8, response, marker) orelse return error.InvalidEmbedResponse;
        var pos = start_pos + marker.len;

        var values = std.ArrayList(f32){};
        errdefer values.deinit();

        while (pos < response.len) {
            // Skip whitespace
            while (pos < response.len and (response[pos] == ' ' or response[pos] == '\n' or response[pos] == '\r' or response[pos] == '\t')) pos += 1;
            if (pos >= response.len) break;
            if (response[pos] == ']') break; // end of array

            // Find end of this number (comma, ] or whitespace)
            const num_start = pos;
            while (pos < response.len and response[pos] != ',' and response[pos] != ']' and response[pos] != ' ' and response[pos] != '\n') pos += 1;
            const num_str = mem.trim(u8, response[num_start..pos], " \t\r\n");
            if (num_str.len > 0) {
                const val = std.fmt.parseFloat(f32, num_str) catch return error.InvalidEmbedFloat;
                try values.append(val);
            }
            // Skip comma
            if (pos < response.len and response[pos] == ',') pos += 1;
        }

        if (values.items.len == 0) return error.EmptyEmbedding;
        return values.toOwnedSlice();
    }
};

/// Client for RAG (Retrieval Augmented Generation)
pub const RAGClient = struct {
    gateway: LLMGatewayClient,
    
    pub fn init(allocator: Allocator, config: GatewayConfig) RAGClient {
        return .{
            .gateway = LLMGatewayClient.init(allocator, config),
        };
    }
    
    /// RAG query with context
    pub fn query(self: *RAGClient, question: []const u8, context: []const u8) ![]const u8 {
        const prompt = try std.fmt.allocPrint(self.gateway.allocator,
            \\Context: {s}
            \\
            \\Question: {s}
            \\
            \\Answer based on the context above:
        , .{ context, question });
        defer self.gateway.allocator.free(prompt);
        
        return self.gateway.chat(prompt);
    }
};

// ============================================================================
// FFI Exports
// ============================================================================

/// Persistent GPA stored on the heap so it outlives the FFI init call.
var ffi_gpa: ?*std.heap.GeneralPurposeAllocator(.{}) = null;

export fn llm_gateway_init(url: [*:0]const u8) callconv(.C) ?*LLMGatewayClient {
    // Use page_allocator for the GPA itself since we need it to live forever
    if (ffi_gpa == null) {
        ffi_gpa = std.heap.page_allocator.create(std.heap.GeneralPurposeAllocator(.{})) catch return null;
        ffi_gpa.?.* = std.heap.GeneralPurposeAllocator(.{}){};
    }
    const allocator = ffi_gpa.?.allocator();
    
    const url_slice = std.mem.span(url);
    const config = GatewayConfig{
        .gateway_url = allocator.dupe(u8, url_slice) catch return null,
    };
    
    const client = allocator.create(LLMGatewayClient) catch return null;
    client.* = LLMGatewayClient.init(allocator, config);
    
    return client;
}

export fn llm_gateway_chat(
    client: ?*LLMGatewayClient,
    prompt: [*:0]const u8,
    out_buf: [*]u8,
    out_len: usize,
) callconv(.C) usize {
    if (client == null) return 0;
    
    const prompt_slice = std.mem.span(prompt);
    const response = client.?.chat(prompt_slice) catch return 0;
    defer client.?.allocator.free(response);
    
    const to_copy = @min(response.len, out_len);
    @memcpy(out_buf[0..to_copy], response[0..to_copy]);
    
    return to_copy;
}

// ============================================================================
// JSON Escaping Helper
// ============================================================================

/// Write a string to a writer with JSON escaping for all special characters.
fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    // Control characters: \u00XX
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "gateway config" {
    const local_config = GatewayConfig.forLocal();
    try std.testing.expectEqualStrings("http://localhost:8080", local_config.gateway_url);
    
    const aicore_config = GatewayConfig.forAICore("https://api.ai.prod.example.com");
    try std.testing.expectEqualStrings("https://api.ai.prod.example.com", aicore_config.gateway_url);
}

test "json escaping" {
    const allocator = std.testing.allocator;
    var client = LLMGatewayClient.init(allocator, .{});
    
    const input = "hello\\nworld";
    const unescaped = try client.unescapeJson(input);
    defer allocator.free(unescaped);
    
    try std.testing.expectEqualStrings("hello\nworld", unescaped);
}
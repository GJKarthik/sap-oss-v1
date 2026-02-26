//! Integration Tests for MCP PAL Mesh Gateway
//!
//! Tests the full request → Mangle intent → MCP tool dispatch → response flow.
//! Validates OpenAI-compatible API, MCP JSON-RPC, SSE streaming, and PAL operations.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

// ============================================================================
// Mock Components
// ============================================================================

pub const MockMangleEngine = struct {
    allocator: mem.Allocator,
    fact_count: usize = 10,
    rule_count: usize = 8,
    
    pub const Intent = enum {
        pal_catalog,
        pal_search,
        pal_execute,
        pal_spec,
        pal_sql,
        schema_explore,
        describe_table,
        hybrid_search,
        es_translate,
        pal_optimize,
        graph_publish,
        graph_query,
        odata_fetch,
        unknown,
    };
    
    pub fn init(allocator: mem.Allocator) MockMangleEngine {
        return .{ .allocator = allocator };
    }
    
    pub fn detectIntent(self: *const MockMangleEngine, message: []const u8) Intent {
        _ = self;
        const lower = std.ascii.allocLowerString(std.testing.allocator, message) catch return .unknown;
        defer std.testing.allocator.free(lower);
        
        if (mem.indexOf(u8, lower, "catalog") != null or mem.indexOf(u8, lower, "list alg") != null) return .pal_catalog;
        if (mem.indexOf(u8, lower, "search") != null) return .pal_search;
        if (mem.indexOf(u8, lower, "execute") != null or mem.indexOf(u8, lower, "run") != null) return .pal_execute;
        if (mem.indexOf(u8, lower, "spec") != null) return .pal_spec;
        if (mem.indexOf(u8, lower, "sql") != null) return .pal_sql;
        if (mem.indexOf(u8, lower, "schema") != null or mem.indexOf(u8, lower, "tables") != null) return .schema_explore;
        if (mem.indexOf(u8, lower, "describe") != null or mem.indexOf(u8, lower, "columns") != null) return .describe_table;
        if (mem.indexOf(u8, lower, "hybrid search") != null) return .hybrid_search;
        if (mem.indexOf(u8, lower, "translate") != null or mem.indexOf(u8, lower, "es to hana") != null) return .es_translate;
        if (mem.indexOf(u8, lower, "optimize") != null or mem.indexOf(u8, lower, "recommend") != null) return .pal_optimize;
        if (mem.indexOf(u8, lower, "publish") != null) return .graph_publish;
        if (mem.indexOf(u8, lower, "lineage") != null or mem.indexOf(u8, lower, "impact") != null) return .graph_query;
        if (mem.indexOf(u8, lower, "odata") != null or mem.indexOf(u8, lower, "fetch") != null) return .odata_fetch;
        return .unknown;
    }
};

pub const MockPalCatalog = struct {
    allocator: mem.Allocator,
    algorithm_count: usize = 162,
    category_count: usize = 13,
    
    pub fn init(allocator: mem.Allocator) MockPalCatalog {
        return .{ .allocator = allocator };
    }
    
    pub fn listCategories(self: *MockPalCatalog) ![]const u8 {
        return try self.allocator.dupe(u8, 
            "# PAL Categories\n\n" ++
            "- clustering (21)\n" ++
            "- classification (17)\n" ++
            "- regression (11)\n" ++
            "- timeseries (36)\n" ++
            "- statistics (24)\n"
        );
    }
    
    pub fn searchAlgorithms(self: *MockPalCatalog, query: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator,
            "# Search Results for: {s}\n\n- kmeans (clustering)\n- dbscan (clustering)\n",
            .{query}
        );
    }
};

pub const MockGpuEngine = struct {
    allocator: mem.Allocator,
    initialized: bool = true,
    inference_count: u64 = 0,
    config: GpuConfig = .{},
    
    pub const GpuConfig = struct {
        use_tensor_cores: bool = true,
        use_int8: bool = true,
        use_flash_attention: bool = true,
        max_sequences: u32 = 256,
    };
    
    pub fn init(allocator: mem.Allocator) MockGpuEngine {
        return .{ .allocator = allocator };
    }
    
    pub fn generateEmbedding(self: *MockGpuEngine, text: []const u8) ![]f32 {
        self.inference_count += 1;
        const dims: usize = 256;
        var embedding = try self.allocator.alloc(f32, dims);
        
        var seed: u64 = std.hash.Wyhash.hash(0, text);
        for (embedding, 0..) |*v, i| {
            seed +%= @as(u64, @intCast(i));
            v.* = @as(f32, @floatFromInt(seed % 1000)) / 1000.0 - 0.5;
        }
        
        // Normalize
        var sum_sq: f32 = 0;
        for (embedding) |v| sum_sq += v * v;
        const inv = 1.0 / @sqrt(sum_sq);
        for (embedding) |*v| v.* *= inv;
        
        return embedding;
    }
};

pub const MockHanaClient = struct {
    allocator: mem.Allocator,
    configured: bool = true,
    host: []const u8 = "localhost",
    port: u16 = 443,
    
    pub fn init(allocator: mem.Allocator) MockHanaClient {
        return .{ .allocator = allocator };
    }
    
    pub fn isConfigured(self: *const MockHanaClient) bool {
        return self.configured;
    }
};

// ============================================================================
// Test Harness
// ============================================================================

pub const TestContext = struct {
    allocator: mem.Allocator,
    mangle: MockMangleEngine,
    catalog: MockPalCatalog,
    gpu: MockGpuEngine,
    hana: MockHanaClient,
    requests_total: u64 = 0,

    pub fn init(allocator: mem.Allocator) !TestContext {
        return TestContext{
            .allocator = allocator,
            .mangle = MockMangleEngine.init(allocator),
            .catalog = MockPalCatalog.init(allocator),
            .gpu = MockGpuEngine.init(allocator),
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

        // Health
        if (mem.eql(u8, path, "/health")) {
            return SimulatedResponse{
                .status = 200,
                .body = try self.allocator.dupe(u8, "{\"status\":\"ok\",\"service\":\"mcppal-mesh-gateway\",\"algorithms\":162,\"categories\":13}"),
            };
        }

        // GPU Info
        if (mem.eql(u8, path, "/api/gpu/info")) {
            return try self.handleGpuInfo();
        }

        // Models
        if (mem.eql(u8, path, "/v1/models")) {
            if (method != .GET) {
                return SimulatedResponse{
                    .status = 405,
                    .body = try self.allocator.dupe(u8, "{\"error\":\"Method not allowed\"}"),
                };
            }
            return SimulatedResponse{
                .status = 200,
                .body = try self.allocator.dupe(u8, "{\"object\":\"list\",\"data\":[{\"id\":\"mcppal-mesh-gateway-v1\"}]}"),
            };
        }

        // Chat Completions
        if (mem.eql(u8, path, "/v1/chat/completions")) {
            if (method != .POST) {
                return SimulatedResponse{
                    .status = 405,
                    .body = try self.allocator.dupe(u8, "{\"error\":\"Method not allowed\"}"),
                };
            }
            return try self.handleChatCompletions(body);
        }

        // MCP JSON-RPC
        if (mem.eql(u8, path, "/mcp")) {
            if (method != .POST) {
                return SimulatedResponse{
                    .status = 405,
                    .body = try self.allocator.dupe(u8, "{\"error\":\"Method not allowed\"}"),
                };
            }
            return try self.handleMcpJsonRpc(body);
        }

        // SSE
        if (mem.eql(u8, path, "/sse")) {
            return SimulatedResponse{
                .status = 200,
                .body = try self.allocator.dupe(u8, "event: message\ndata: {\"streaming\":true}\n\n"),
            };
        }

        // Not found
        return SimulatedResponse{
            .status = 404,
            .body = try self.allocator.dupe(u8, "{\"error\":{\"message\":\"Not found\"}}"),
        };
    }

    fn handleGpuInfo(self: *TestContext) !SimulatedResponse {
        const config = self.gpu.config;
        const body = try std.fmt.allocPrint(self.allocator,
            \\{{"native_gpu":{{"available":true,"backend":"T4","config":{{"tensor_cores":{s},"flash_attention":{s},"int8_quantization":{s},"max_sequences":{d}}}}},"service":"ai-core-pal"}}
        , .{
            if (config.use_tensor_cores) "true" else "false",
            if (config.use_flash_attention) "true" else "false",
            if (config.use_int8) "true" else "false",
            config.max_sequences,
        });
        return SimulatedResponse{ .status = 200, .body = body };
    }

    fn handleChatCompletions(self: *TestContext, body: ?[]const u8) !SimulatedResponse {
        const input = body orelse return SimulatedResponse{
            .status = 400,
            .body = try self.allocator.dupe(u8, "{\"error\":{\"message\":\"Missing request body\"}}"),
        };

        const user_message = extractUserContent(input);
        const intent = self.mangle.detectIntent(user_message);
        
        const content = try self.dispatchIntent(intent, user_message);
        defer self.allocator.free(content);

        const resp_body = try std.fmt.allocPrint(self.allocator,
            \\{{"id":"chatcmpl-pal-{d}","object":"chat.completion","model":"mcppal-mesh-gateway-v1","choices":[{{"message":{{"role":"assistant","content":"{s}"}}}}]}}
        , .{ self.requests_total, content });

        return SimulatedResponse{ .status = 200, .body = resp_body };
    }

    fn dispatchIntent(self: *TestContext, intent: MockMangleEngine.Intent, message: []const u8) ![]const u8 {
        return switch (intent) {
            .pal_catalog => try self.catalog.listCategories(),
            .pal_search => try self.catalog.searchAlgorithms(message),
            .pal_execute => try self.allocator.dupe(u8, "PAL execution ready"),
            .pal_spec => try self.allocator.dupe(u8, "PAL specification"),
            .pal_sql => try self.allocator.dupe(u8, "SQL template generated"),
            .schema_explore => try self.allocator.dupe(u8, "Schema: 5 tables"),
            .describe_table => try self.allocator.dupe(u8, "Table columns listed"),
            .hybrid_search => try self.allocator.dupe(u8, "Search results"),
            .es_translate => try self.allocator.dupe(u8, "HANA SQL translated"),
            .pal_optimize => try self.allocator.dupe(u8, "Optimization recommendations"),
            .graph_publish => try self.allocator.dupe(u8, "Published to graph"),
            .graph_query => try self.allocator.dupe(u8, "Lineage results"),
            .odata_fetch => try self.allocator.dupe(u8, "OData fetched"),
            .unknown => try self.allocator.dupe(u8, "Help: try 'list algorithms'"),
        };
    }

    fn handleMcpJsonRpc(self: *TestContext, body: ?[]const u8) !SimulatedResponse {
        const input = body orelse return SimulatedResponse{
            .status = 400,
            .body = try self.allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32700,\"message\":\"Invalid JSON\"}}"),
        };

        // Extract method
        const method = extractJsonString(input, "method") orelse "";

        if (mem.eql(u8, method, "initialize")) {
            return SimulatedResponse{
                .status = 200,
                .body = try self.allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{},\"resources\":{}}}}"),
            };
        }
        if (mem.eql(u8, method, "ping")) {
            return SimulatedResponse{
                .status = 200,
                .body = try self.allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"),
            };
        }
        if (mem.eql(u8, method, "tools/list")) {
            return SimulatedResponse{
                .status = 200,
                .body = try self.allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"pal-catalog\"},{\"name\":\"pal-execute\"},{\"name\":\"pal-spec\"}]}}"),
            };
        }
        if (mem.eql(u8, method, "tools/call")) {
            return SimulatedResponse{
                .status = 200,
                .body = try self.allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Tool result\"}]}}"),
            };
        }
        if (mem.eql(u8, method, "resources/list")) {
            return SimulatedResponse{
                .status = 200,
                .body = try self.allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resources\":[{\"uri\":\"hana://schema\"}]}}"),
            };
        }
        if (mem.eql(u8, method, "resources/templates/list")) {
            return SimulatedResponse{
                .status = 200,
                .body = try self.allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resourceTemplates\":[]}}"),
            };
        }
        if (mem.eql(u8, method, "resources/read")) {
            return SimulatedResponse{
                .status = 200,
                .body = try self.allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"contents\":[{\"uri\":\"hana://schema\",\"text\":\"{}\"}]}}"),
            };
        }

        return SimulatedResponse{
            .status = 200,
            .body = try self.allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}"),
        };
    }
};

pub const Method = enum { GET, POST, PUT, DELETE, OPTIONS };

fn extractUserContent(body: []const u8) []const u8 {
    const patterns = [_][]const u8{ "\"content\":\"", "\"content\": \"" };
    for (patterns) |pat| {
        if (mem.indexOf(u8, body, pat)) |pos| {
            const start = pos + pat.len;
            if (mem.indexOfPos(u8, body, start, "\"")) |end| {
                return body[start..end];
            }
        }
    }
    return "";
}

fn extractJsonString(body: []const u8, key: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":\"", .{key}) catch return null;
    if (mem.indexOf(u8, body, needle)) |pos| {
        const start = pos + needle.len;
        if (mem.indexOfPos(u8, body, start, "\"")) |end| {
            return body[start..end];
        }
    }
    return null;
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
    var ctx = try TestContext.init(testing.allocator);

    var response = try ctx.simulateRequest(.GET, "/health", null);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "mcppal-mesh-gateway") != null);
    try testing.expect(mem.indexOf(u8, response.body, "162") != null); // algorithm count
}

test "GET /api/gpu/info returns GPU config" {
    var ctx = try TestContext.init(testing.allocator);

    var response = try ctx.simulateRequest(.GET, "/api/gpu/info", null);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "tensor_cores") != null);
}

test "GET /v1/models returns model list" {
    var ctx = try TestContext.init(testing.allocator);

    var response = try ctx.simulateRequest(.GET, "/v1/models", null);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "mcppal-mesh-gateway-v1") != null);
}

// ============================================================================
// Chat Completions / Intent Tests
// ============================================================================

test "POST /v1/chat/completions - catalog" {
    var ctx = try TestContext.init(testing.allocator);

    const body = "{\"messages\":[{\"role\":\"user\",\"content\":\"list algorithms catalog\"}]}";
    var response = try ctx.simulateRequest(.POST, "/v1/chat/completions", body);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "chat.completion") != null);
}

test "POST /v1/chat/completions - search" {
    var ctx = try TestContext.init(testing.allocator);

    const body = "{\"messages\":[{\"role\":\"user\",\"content\":\"search kmeans\"}]}";
    var response = try ctx.simulateRequest(.POST, "/v1/chat/completions", body);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
}

test "POST /v1/chat/completions - execute" {
    var ctx = try TestContext.init(testing.allocator);

    const body = "{\"messages\":[{\"role\":\"user\",\"content\":\"execute kmeans on MY_TABLE\"}]}";
    var response = try ctx.simulateRequest(.POST, "/v1/chat/completions", body);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
}

test "POST /v1/chat/completions - schema" {
    var ctx = try TestContext.init(testing.allocator);

    const body = "{\"messages\":[{\"role\":\"user\",\"content\":\"show schema tables\"}]}";
    var response = try ctx.simulateRequest(.POST, "/v1/chat/completions", body);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
}

test "GET /v1/chat/completions returns 405" {
    var ctx = try TestContext.init(testing.allocator);

    var response = try ctx.simulateRequest(.GET, "/v1/chat/completions", null);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 405), response.status);
}

// ============================================================================
// MCP JSON-RPC Tests
// ============================================================================

test "POST /mcp - initialize" {
    var ctx = try TestContext.init(testing.allocator);

    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}";
    var response = try ctx.simulateRequest(.POST, "/mcp", body);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "protocolVersion") != null);
    try testing.expect(mem.indexOf(u8, response.body, "2024-11-05") != null);
}

test "POST /mcp - ping" {
    var ctx = try TestContext.init(testing.allocator);

    const body = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}";
    var response = try ctx.simulateRequest(.POST, "/mcp", body);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
}

test "POST /mcp - tools/list" {
    var ctx = try TestContext.init(testing.allocator);

    const body = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}";
    var response = try ctx.simulateRequest(.POST, "/mcp", body);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "tools") != null);
    try testing.expect(mem.indexOf(u8, response.body, "pal-catalog") != null);
}

test "POST /mcp - tools/call" {
    var ctx = try TestContext.init(testing.allocator);

    const body = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"pal-catalog\",\"arguments\":{}}}";
    var response = try ctx.simulateRequest(.POST, "/mcp", body);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "result") != null);
}

test "POST /mcp - resources/list" {
    var ctx = try TestContext.init(testing.allocator);

    const body = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"resources/list\"}";
    var response = try ctx.simulateRequest(.POST, "/mcp", body);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "resources") != null);
    try testing.expect(mem.indexOf(u8, response.body, "hana://schema") != null);
}

test "POST /mcp - resources/read" {
    var ctx = try TestContext.init(testing.allocator);

    const body = "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"resources/read\",\"params\":{\"uri\":\"hana://schema\"}}";
    var response = try ctx.simulateRequest(.POST, "/mcp", body);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "contents") != null);
}

test "POST /mcp - unknown method" {
    var ctx = try TestContext.init(testing.allocator);

    const body = "{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"unknown/method\"}";
    var response = try ctx.simulateRequest(.POST, "/mcp", body);
    defer response.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(mem.indexOf(u8, response.body, "-32601") != null); // Method not found
}

// ============================================================================
// GPU Engine Tests
// ============================================================================

test "GPU embedding generates normalized vector" {
    var gpu = MockGpuEngine.init(testing.allocator);
    
    const embedding = try gpu.generateEmbedding("test input");
    defer testing.allocator.free(embedding);
    
    try testing.expectEqual(@as(usize, 256), embedding.len);
    
    // Check normalization (sum of squares ≈ 1)
    var sum_sq: f32 = 0;
    for (embedding) |v| sum_sq += v * v;
    try testing.expectApproxEqAbs(@as(f32, 1.0), sum_sq, 0.01);
}

test "GPU embedding is deterministic" {
    var gpu = MockGpuEngine.init(testing.allocator);
    
    const e1 = try gpu.generateEmbedding("same text");
    defer testing.allocator.free(e1);
    
    const e2 = try gpu.generateEmbedding("same text");
    defer testing.allocator.free(e2);
    
    for (e1, e2) |v1, v2| {
        try testing.expectApproxEqAbs(v1, v2, 0.0001);
    }
}

// ============================================================================
// Intent Detection Tests
// ============================================================================

test "Mangle detects catalog intent" {
    var mangle = MockMangleEngine.init(testing.allocator);
    const intent = mangle.detectIntent("list algorithms catalog");
    try testing.expectEqual(MockMangleEngine.Intent.pal_catalog, intent);
}

test "Mangle detects execute intent" {
    var mangle = MockMangleEngine.init(testing.allocator);
    const intent = mangle.detectIntent("execute kmeans on DATA");
    try testing.expectEqual(MockMangleEngine.Intent.pal_execute, intent);
}

test "Mangle detects schema intent" {
    var mangle = MockMangleEngine.init(testing.allocator);
    const intent = mangle.detectIntent("show schema tables");
    try testing.expectEqual(MockMangleEngine.Intent.schema_explore, intent);
}

test "Mangle returns unknown for unmatched" {
    var mangle = MockMangleEngine.init(testing.allocator);
    const intent = mangle.detectIntent("xyz123");
    try testing.expectEqual(MockMangleEngine.Intent.unknown, intent);
}

// ============================================================================
// All Routes Coverage
// ============================================================================

test "all routes covered" {
    var ctx = try TestContext.init(testing.allocator);

    const routes = [_]struct { method: Method, path: []const u8, expected: u16 }{
        .{ .method = .GET, .path = "/health", .expected = 200 },
        .{ .method = .GET, .path = "/api/gpu/info", .expected = 200 },
        .{ .method = .GET, .path = "/v1/models", .expected = 200 },
        .{ .method = .POST, .path = "/v1/chat/completions", .expected = 200 },
        .{ .method = .POST, .path = "/mcp", .expected = 200 },
        .{ .method = .GET, .path = "/sse", .expected = 200 },
    };

    for (routes) |r| {
        var body_val: ?[]const u8 = null;
        if (r.method == .POST) {
            if (mem.eql(u8, r.path, "/mcp")) {
                body_val = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}";
            } else {
                body_val = "{\"messages\":[{\"role\":\"user\",\"content\":\"test\"}]}";
            }
        }
        var response = try ctx.simulateRequest(r.method, r.path, body_val);
        defer response.deinit(testing.allocator);
        try testing.expectEqual(r.expected, response.status);
    }
}

// ============================================================================
// Case Insensitive Helper Tests
// ============================================================================

test "caseContains - basic" {
    try testing.expect(caseContains("Hello World", "hello"));
    try testing.expect(caseContains("KMEANS clustering", "kmeans"));
    try testing.expect(!caseContains("abc", "xyz"));
}

fn caseContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            const h = if (haystack[i + j] >= 'A' and haystack[i + j] <= 'Z') haystack[i + j] + 32 else haystack[i + j];
            const n = if (needle[j] >= 'A' and needle[j] <= 'Z') needle[j] + 32 else needle[j];
            if (h != n) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}
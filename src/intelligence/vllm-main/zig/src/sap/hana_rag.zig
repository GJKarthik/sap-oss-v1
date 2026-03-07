// =============================================================================
// HANA PAL RAG Integration for Local Models Service
// =============================================================================
//
// Integrates local LLM inference with HANA PAL RAG:
// - Calls HANA stored procedures for retrieval
// - Uses local models for LLM synthesis
// - Provides OpenAI-compatible RAG endpoints
//
// Architecture:
//   User Query → local-models → HANA PAL (retrieval) → local LLM (synthesis) → Response

const std = @import("std");
const json = std.json;
const mem = std.mem;
const posix = std.posix;
const Allocator = std.mem.Allocator;

// =============================================================================
// HANA RAG Client Configuration
// =============================================================================

pub const HanaRAGConfig = struct {
    // HANA connection
    hana_host: []const u8 = "localhost",
    hana_port: u16 = 443,
    hana_user: []const u8 = "",
    hana_password: []const u8 = "",
    hana_schema: []const u8 = "SEARCH_SVC",

    // RAG settings
    default_index: []const u8 = "documents",
    top_k: usize = 5,
    search_strategy: SearchStrategy = .hybrid,

    // LLM settings
    llm_model: []const u8 = "LFM2.5-1.2B-Instruct-GGUF",
    temperature: f32 = 0.7,
    max_tokens: usize = 512,

    // Prompt settings
    prompt_template: PromptTemplate = .strict,

    pub const SearchStrategy = enum {
        vector,
        keyword,
        hybrid,
    };

    pub const PromptTemplate = enum {
        strict,
        flexible,
        summarize,
    };
};

// =============================================================================
// RAG Request/Response Types
// =============================================================================

pub const RAGRequest = struct {
    query: []const u8,
    index_name: ?[]const u8 = null,
    top_k: ?usize = null,
    search_strategy: ?[]const u8 = null,
    model: ?[]const u8 = null,
    temperature: ?f32 = null,
    include_context: bool = true,
    include_citations: bool = true,
};

pub const RAGResponse = struct {
    answer: []const u8,
    model: []const u8,
    citations: []const Citation,
    context_used: ?[]const u8,
    retrieval_count: usize,
    confidence: f32,

    pub const Citation = struct {
        chunk_id: []const u8,
        doc_id: []const u8,
        title: []const u8,
        excerpt: []const u8,
        score: f32,
    };
};

// =============================================================================
// HANA RAG Client
// =============================================================================

pub const HanaRAGClient = struct {
    allocator: Allocator,
    config: HanaRAGConfig,
    hana_connection: ?*anyopaque = null,

    pub fn init(allocator: Allocator, config: HanaRAGConfig) !HanaRAGClient {
        return HanaRAGClient{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *HanaRAGClient) void {
        _ = self;
    }

    // =========================================================================
    // Main RAG Query
    // =========================================================================

    pub fn query(self: *HanaRAGClient, request: RAGRequest) !RAGResponse {
        const index = request.index_name orelse self.config.default_index;
        const top_k = request.top_k orelse self.config.top_k;
        const model = request.model orelse self.config.llm_model;
        const temperature = request.temperature orelse self.config.temperature;

        // Step 1: Call HANA RAG_QUERY procedure
        const retrieval_result = try self.callHanaRagQuery(
            request.query,
            index,
            top_k,
        );
        defer {
            self.allocator.free(retrieval_result.context);
            for (retrieval_result.chunks) |chunk| {
                self.allocator.free(chunk.chunk_id);
                self.allocator.free(chunk.doc_id);
                self.allocator.free(chunk.title);
                self.allocator.free(chunk.content);
            }
            self.allocator.free(retrieval_result.chunks);
        }

        // Step 2: Generate prompt with context
        const prompt = try self.buildRAGPrompt(request.query, retrieval_result.context);
        defer self.allocator.free(prompt);

        // Step 3: Call local LLM for synthesis
        const answer = try self.callLocalLLM(prompt, model, temperature);

        // Step 4: Build citations
        var citations = try self.allocator.alloc(RAGResponse.Citation, retrieval_result.chunks.len);
        for (retrieval_result.chunks, 0..) |chunk, i| {
            citations[i] = RAGResponse.Citation{
                .chunk_id = try self.allocator.dupe(u8, chunk.chunk_id),
                .doc_id = try self.allocator.dupe(u8, chunk.doc_id),
                .title = try self.allocator.dupe(u8, chunk.title),
                .excerpt = if (chunk.content.len > 150)
                    try self.allocator.dupe(u8, chunk.content[0..150])
                else
                    try self.allocator.dupe(u8, chunk.content),
                .score = chunk.score,
            };
        }

        // Step 5: Calculate confidence
        var avg_score: f32 = 0.0;
        for (retrieval_result.chunks) |chunk| {
            avg_score += chunk.score;
        }
        if (retrieval_result.chunks.len > 0) {
            avg_score /= @as(f32, @floatFromInt(retrieval_result.chunks.len));
        }

        return RAGResponse{
            .answer = answer,
            .model = model,
            .citations = citations,
            .context_used = if (request.include_context)
                try self.allocator.dupe(u8, retrieval_result.context)
            else
                null,
            .retrieval_count = retrieval_result.chunks.len,
            .confidence = @min(avg_score, 1.0),
        };
    }

    // =========================================================================
    // HANA RAG Procedure Calls
    // =========================================================================

    const RetrievalResult = struct {
        context: []const u8,
        chunks: []const RetrievedChunk,
    };

    const RetrievedChunk = struct {
        chunk_id: []const u8,
        doc_id: []const u8,
        title: []const u8,
        content: []const u8,
        score: f32,
    };

    const MeshGatewayTarget = struct {
        scheme: []const u8,
        host: []const u8,
        port: u16,
    };

    fn callHanaRagQuery(
        self: *HanaRAGClient,
        user_query: []const u8,
        index_name: []const u8,
        top_k: usize,
    ) !RetrievalResult {
        // Route retrieval through mcppal mesh gateway MCP tools instead of direct HANA SQL.
        _ = index_name;
        const response = try self.executeMeshHybridSearch(user_query, top_k);
        defer self.allocator.free(response);

        // Parse response
        return self.parseRetrievalResult(response);
    }

    fn executeMeshHybridSearch(self: *HanaRAGClient, search_query: []const u8, top_k: usize) ![]u8 {
        const target = resolveMeshGatewayTarget();

        // JSON-RPC tools/call request for mesh-gateway MCP endpoint.
        var rpc_body_buf: std.ArrayList(u8) = .{};
        defer rpc_body_buf.deinit();
        const bw = rpc_body_buf.writer();
        try bw.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"hybrid-search\",\"arguments\":{\"query\":");
        try writeJsonStringRaw(bw, search_query);
        try bw.writeAll("}}}");
        const rpc_body = try rpc_body_buf.toOwnedSlice();
        defer self.allocator.free(rpc_body);

        const endpoint = try std.fmt.allocPrint(
            self.allocator,
            "{s}://{s}:{d}/mcp",
            .{ target.scheme, target.host, target.port },
        );
        defer self.allocator.free(endpoint);

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        var response_body: std.ArrayList(u8) = .{};
        defer response_body.deinit();
        var response_writer = response_body.writer();
        var response_writer_buf: [1024]u8 = undefined;
        var response_writer_adapter = response_writer.adaptToNewApi(&response_writer_buf);
        const result = try client.fetch(.{
            .location = .{ .url = endpoint },
            .method = .POST,
            .payload = rpc_body,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Accept", .value = "application/json" },
            },
            .response_writer = &response_writer_adapter.new_interface,
        });
        try response_writer_adapter.new_interface.flush();

        const status_code: u16 = @intFromEnum(result.status);
        if (status_code < 200 or status_code >= 300) {
            std.log.err("mesh-gateway MCP request failed ({d}): {s}", .{ status_code, response_body.items });
            return error.MeshGatewayRequestFailed;
        }

        return self.normalizeMeshMcpResponse(response_body.items, top_k);
    }

    fn normalizeMeshMcpResponse(self: *HanaRAGClient, mcp_body: []const u8, top_k: usize) ![]u8 {
        const parsed = json.parseFromSlice(json.Value, self.allocator, mcp_body, .{}) catch {
            return try self.wrapPlainContext("No relevant documents found.");
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            return try self.wrapPlainContext("No relevant documents found.");
        }

        if (parsed.value.object.get("error")) |err_val| {
            if (err_val == .object) {
                if (err_val.object.get("message")) |message| {
                    if (message == .string) return try self.wrapPlainContext(message.string);
                }
            }
            return try self.wrapPlainContext("Mesh gateway returned an error.");
        }

        const result = parsed.value.object.get("result") orelse return try self.wrapPlainContext("No relevant documents found.");
        if (result != .object) return try self.wrapPlainContext("No relevant documents found.");

        const content = result.object.get("content") orelse return try self.wrapPlainContext("No relevant documents found.");
        if (content != .array or content.array.items.len == 0) return try self.wrapPlainContext("No relevant documents found.");

        const first = content.array.items[0];
        if (first != .object) return try self.wrapPlainContext("No relevant documents found.");
        const text_val = first.object.get("text") orelse return try self.wrapPlainContext("No relevant documents found.");
        if (text_val != .string) return try self.wrapPlainContext("No relevant documents found.");

        const text = text_val.string;
        if (text.len == 0) return try self.wrapPlainContext("No relevant documents found.");

        // If the tool text is JSON with hits, map it to hana_rag retrieval schema.
        const search_parsed = json.parseFromSlice(json.Value, self.allocator, text, .{}) catch {
            return try self.wrapPlainContext(text);
        };
        defer search_parsed.deinit();

        if (search_parsed.value != .object) return try self.wrapPlainContext(text);
        const hits_obj = search_parsed.value.object.get("hits") orelse return try self.wrapPlainContext(text);
        if (hits_obj != .object) return try self.wrapPlainContext(text);
        const hits_arr_val = hits_obj.object.get("hits") orelse return try self.wrapPlainContext(text);
        if (hits_arr_val != .array) return try self.wrapPlainContext(text);

        var out: std.ArrayList(u8) = .{};
        defer out.deinit();
        const ow = out.writer();

        try ow.writeAll("{\"context\":");
        var context_buf: std.ArrayList(u8) = .{};
        defer context_buf.deinit();
        const cw = context_buf.writer();

        for (hits_arr_val.array.items, 0..) |hit, i| {
            if (i >= top_k) break;
            if (hit != .object) continue;

            const source = if (hit.object.get("_source")) |src| src else hit;
            const title = extractStringField(source, "title") orelse "Untitled";
            const content_text = extractStringField(source, "content") orelse "";

            try cw.print("[{d}] {s}\n{s}\n\n", .{ i + 1, title, content_text });
        }

        try writeJsonStringRaw(ow, context_buf.items);
        try ow.writeAll(",\"chunks\":[");

        var first_chunk = true;
        for (hits_arr_val.array.items, 0..) |hit, i| {
            if (i >= top_k) break;
            if (hit != .object) continue;

            const source = if (hit.object.get("_source")) |src| src else hit;
            const chunk_id = extractStringField(hit, "_id") orelse extractStringField(hit, "id") orelse "chunk";
            const doc_id = extractStringField(source, "doc_id") orelse chunk_id;
            const title = extractStringField(source, "title") orelse "Untitled";
            const content_text = extractStringField(source, "content") orelse "";
            const score = extractFloatField(hit, "_score") orelse extractFloatField(hit, "score") orelse 0.0;

            if (!first_chunk) try ow.writeAll(",");
            first_chunk = false;

            try ow.writeAll("{\"chunk_id\":");
            try writeJsonStringRaw(ow, chunk_id);
            try ow.writeAll(",\"doc_id\":");
            try writeJsonStringRaw(ow, doc_id);
            try ow.writeAll(",\"title\":");
            try writeJsonStringRaw(ow, title);
            try ow.writeAll(",\"content\":");
            try writeJsonStringRaw(ow, content_text);
            try ow.print(",\"score\":{d}}}", .{score});
        }

        try ow.writeAll("]}");
        return out.toOwnedSlice();
    }

    fn wrapPlainContext(self: *HanaRAGClient, text: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .{};
        defer out.deinit();
        const w = out.writer();
        try w.writeAll("{\"context\":");
        try writeJsonStringRaw(w, text);
        try w.writeAll(",\"chunks\":[]}");
        return out.toOwnedSlice();
    }

    fn resolveMeshGatewayTarget() MeshGatewayTarget {
        const url = std.posix.getenv("MESH_GATEWAY_URL") orelse std.posix.getenv("SVC_MESH_GATEWAY_URL") orelse "localhost";
        const port_env = std.posix.getenv("MESH_GATEWAY_PORT") orelse std.posix.getenv("SVC_MESH_GATEWAY_PORT");

        var scheme: []const u8 = "http";
        var host: []const u8 = url;
        var port: u16 = 9881;

        if (mem.startsWith(u8, host, "https://")) {
            scheme = "https";
            host = host["https://".len..];
            if (port_env == null) port = 443;
        } else if (mem.startsWith(u8, host, "http://")) {
            scheme = "http";
            host = host["http://".len..];
            if (port_env == null) port = 80;
        }

        if (mem.indexOf(u8, host, "/")) |slash| {
            host = host[0..slash];
        }
        if (mem.indexOf(u8, host, ":")) |colon| {
            if (port_env == null) {
                port = std.fmt.parseInt(u16, host[colon + 1 ..], 10) catch port;
            }
            host = host[0..colon];
        }

        if (port_env) |p| {
            port = std.fmt.parseInt(u16, p, 10) catch port;
        }
        if (host.len == 0) host = "localhost";

        return .{
            .scheme = scheme,
            .host = host,
            .port = port,
        };
    }

    fn extractStringField(value: std.json.Value, key: []const u8) ?[]const u8 {
        if (value != .object) return null;
        const v = value.object.get(key) orelse return null;
        if (v != .string) return null;
        return v.string;
    }

    fn extractFloatField(value: std.json.Value, key: []const u8) ?f64 {
        if (value != .object) return null;
        const v = value.object.get(key) orelse return null;
        return switch (v) {
            .float => v.float,
            .integer => @floatFromInt(v.integer),
            else => null,
        };
    }

    fn writeJsonStringRaw(writer: anytype, s: []const u8) !void {
        try writer.writeByte('"');
        for (s) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => try writer.writeByte(c),
            }
        }
        try writer.writeByte('"');
    }

    fn parseRetrievalResult(self: *HanaRAGClient, response: []const u8) !RetrievalResult {
        const parsed = json.parseFromSlice(json.Value, self.allocator, response, .{}) catch |err| {
            std.log.warn("parseRetrievalResult: JSON parse failed ({s}), returning empty context", .{@errorName(err)});
            return RetrievalResult{
                .context = try self.allocator.dupe(u8, "No relevant documents found."),
                .chunks = &[_]RetrievedChunk{},
            };
        };
        defer parsed.deinit();

        const root = parsed.value.object;

        const context = if (root.get("context")) |c|
            if (c == .string) try self.allocator.dupe(u8, c.string) else try self.allocator.dupe(u8, "")
        else
            try self.allocator.dupe(u8, "");

        var chunks: std.ArrayList(RetrievedChunk) = .{};
        defer chunks.deinit();

        if (root.get("chunks")) |chunks_json| {
            if (chunks_json == .array) {
                for (chunks_json.array.items) |item| {
                    if (item == .object) {
                        const chunk = RetrievedChunk{
                            .chunk_id = if (item.object.get("chunk_id")) |v| if (v == .string) try self.allocator.dupe(u8, v.string) else "" else "",
                            .doc_id = if (item.object.get("doc_id")) |v| if (v == .string) try self.allocator.dupe(u8, v.string) else "" else "",
                            .title = if (item.object.get("title")) |v| if (v == .string) try self.allocator.dupe(u8, v.string) else "" else "",
                            .content = if (item.object.get("content")) |v| if (v == .string) try self.allocator.dupe(u8, v.string) else "" else "",
                            .score = if (item.object.get("score")) |v| switch (v) {
                                .float => @floatCast(v.float),
                                .integer => @floatFromInt(v.integer),
                                else => 0.0,
                            } else 0.0,
                        };
                        try chunks.append(chunk);
                    }
                }
            }
        }

        return RetrievalResult{
            .context = context,
            .chunks = try chunks.toOwnedSlice(),
        };
    }

    // =========================================================================
    // Prompt Building
    // =========================================================================

    fn buildRAGPrompt(self: *HanaRAGClient, user_query: []const u8, context: []const u8) ![]u8 {
        const system_prompt = switch (self.config.prompt_template) {
            .strict =>
            \\You are a helpful assistant that answers questions based ONLY on the provided context.
            \\Rules:
            \\1. Only use information from the retrieved documents above.
            \\2. If the answer is not in the context, say "I don't have enough information to answer that."
            \\3. Cite sources using [1], [2], etc. when referencing specific documents.
            \\4. Be concise and factual.
            ,
            .flexible =>
            \\You are a helpful assistant. Use the retrieved context to inform your answers.
            \\Guidelines:
            \\1. Prioritize information from the provided documents.
            \\2. You may supplement with general knowledge when the context is insufficient.
            \\3. Clearly distinguish between information from context vs general knowledge.
            \\4. Cite sources using [1], [2], etc. when referencing specific documents.
            ,
            .summarize =>
            \\You are a document summarization assistant.
            \\Task: Summarize the key points from the provided documents.
            \\Guidelines:
            \\1. Focus on the main ideas and findings.
            \\2. Organize the summary logically.
            \\3. Keep the summary concise but comprehensive.
            ,
        };

        return std.fmt.allocPrint(self.allocator,
            \\{s}
            \\
            \\## Retrieved Context:
            \\
            \\{s}
            \\
            \\## Question:
            \\
            \\{s}
            \\
            \\## Answer:
        , .{ system_prompt, context, user_query });
    }

    // =========================================================================
    // Local LLM Call
    // =========================================================================

    fn callLocalLLM(self: *HanaRAGClient, prompt: []const u8, model: []const u8, temperature: f32) ![]u8 {
        // Call local inference endpoint (llm_backend.zig)
        const request_body = try std.fmt.allocPrint(self.allocator,
            \\{{"model":"{s}","messages":[{{"role":"user","content":"{s}"}}],"temperature":{d:.2}}}
        , .{ model, prompt, temperature });
        defer self.allocator.free(request_body);

        // Make HTTP request to local inference server
        const response = try self.httpPost("http://localhost:3000/v1/chat/completions", request_body);
        defer self.allocator.free(response);

        // Parse response
        return self.parseLLMResponse(response);
    }

    fn httpPost(self: *HanaRAGClient, url: []const u8, body: []const u8) ![]u8 {
        const uri = try std.Uri.parse(url);
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        var header_buf: [4096]u8 = undefined;
        var req = try client.open(.POST, uri, .{ .server_header_buffer = &header_buf });
        defer req.deinit();

        req.headers.content_type = .{ .override = "application/json" };
        try req.send();
        try req.writeAll(body);
        try req.finish();
        try req.wait();

        return req.reader().readAllAlloc(self.allocator, 4 * 1024 * 1024);
    }

    fn parseLLMResponse(self: *HanaRAGClient, response: []const u8) ![]u8 {
        const parsed = json.parseFromSlice(json.Value, self.allocator, response, .{}) catch |err| {
            std.log.warn("parseLLMResponse: JSON parse failed ({s}), returning fallback", .{@errorName(err)});
            return self.allocator.dupe(u8, "Error parsing LLM response.");
        };
        defer parsed.deinit();

        const root = parsed.value.object;

        if (root.get("choices")) |choices| {
            if (choices == .array and choices.array.items.len > 0) {
                const first = choices.array.items[0];
                if (first == .object) {
                    if (first.object.get("message")) |message| {
                        if (message == .object) {
                            if (message.object.get("content")) |content| {
                                if (content == .string) {
                                    return self.allocator.dupe(u8, content.string);
                                }
                            }
                        }
                    }
                }
            }
        }

        return self.allocator.dupe(u8, "No response generated.");
    }

    // =========================================================================
    // OpenAI-Compatible Response Formatting
    // =========================================================================

    pub fn formatAsOpenAIResponse(self: *HanaRAGClient, rag_response: RAGResponse) ![]u8 {
        const id = try std.fmt.allocPrint(self.allocator, "chatcmpl-rag-{d}", .{std.time.milliTimestamp()});
        defer self.allocator.free(id);

        // Build answer with citations
        var full_answer: std.ArrayList(u8) = .{};
        defer full_answer.deinit();
        try full_answer.appendSlice(rag_response.answer);

        if (rag_response.citations.len > 0) {
            try full_answer.appendSlice("\n\nSources:\n");
            for (rag_response.citations, 0..) |cit, i| {
                try full_answer.writer().print("[{d}] {s}\n", .{ i + 1, cit.title });
            }
        }

        const answer_text = try full_answer.toOwnedSlice();
        defer self.allocator.free(answer_text);

        const prompt_tokens: i64 = 100; // Approximate
        const completion_tokens: i64 = @intCast(answer_text.len / 4);

        return std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "id": "{s}",
            \\  "object": "chat.completion",
            \\  "created": {d},
            \\  "model": "{s}",
            \\  "choices": [{{
            \\    "index": 0,
            \\    "message": {{
            \\      "role": "assistant",
            \\      "content": "{s}"
            \\    }},
            \\    "finish_reason": "stop"
            \\  }}],
            \\  "usage": {{
            \\    "prompt_tokens": {d},
            \\    "completion_tokens": {d},
            \\    "total_tokens": {d}
            \\  }},
            \\  "rag_metadata": {{
            \\    "retrieval_count": {d},
            \\    "confidence": {d:.3}
            \\  }}
            \\}}
        , .{ id, std.time.timestamp(), rag_response.model, answer_text, prompt_tokens, completion_tokens, prompt_tokens + completion_tokens, rag_response.retrieval_count, rag_response.confidence });
    }
};

// =============================================================================
// Tests
// =============================================================================

test "HanaRAGClient init" {
    const allocator = std.testing.allocator;
    const config = HanaRAGConfig{};
    var client = try HanaRAGClient.init(allocator, config);
    defer client.deinit();

    try std.testing.expectEqualStrings("LFM2.5-1.2B-Instruct-GGUF", client.config.llm_model);
}

test "normalizeMeshMcpResponse maps hybrid-search hits into retrieval schema" {
    const allocator = std.testing.allocator;

    var client = try HanaRAGClient.init(allocator, HanaRAGConfig{});
    defer client.deinit();

    const mcp_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\"hits\":{\"hits\":[{\"_id\":\"chunk-1\",\"_score\":0.91,\"_source\":{\"doc_id\":\"doc-1\",\"title\":\"Title A\",\"content\":\"Body A\"}},{\"_id\":\"chunk-2\",\"_score\":0.73,\"_source\":{\"doc_id\":\"doc-2\",\"title\":\"Title B\",\"content\":\"Body B\"}}]}}"}]}}
    ;

    const normalized = try client.normalizeMeshMcpResponse(mcp_response, 2);
    defer allocator.free(normalized);

    try std.testing.expect(mem.indexOf(u8, normalized, "\"chunk_id\":\"chunk-1\"") != null);
    try std.testing.expect(mem.indexOf(u8, normalized, "\"doc_id\":\"doc-2\"") != null);
    try std.testing.expect(mem.indexOf(u8, normalized, "[1] Title A") != null);
}

test "normalizeMeshMcpResponse wraps plain tool text" {
    const allocator = std.testing.allocator;

    var client = try HanaRAGClient.init(allocator, HanaRAGConfig{});
    defer client.deinit();

    const mcp_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"fallback context from mesh gateway"}]}}
    ;

    const normalized = try client.normalizeMeshMcpResponse(mcp_response, 3);
    defer allocator.free(normalized);

    try std.testing.expect(mem.indexOf(u8, normalized, "\"chunks\":[]") != null);
    try std.testing.expect(mem.indexOf(u8, normalized, "fallback context from mesh gateway") != null);
}

test "parseRetrievalResult returns empty context on invalid JSON" {
    const allocator = std.testing.allocator;
    var client = try HanaRAGClient.init(allocator, HanaRAGConfig{});
    defer client.deinit();

    const result = try client.parseRetrievalResult("not valid json at all");
    defer allocator.free(result.context);

    try std.testing.expectEqualStrings("No relevant documents found.", result.context);
    try std.testing.expectEqual(@as(usize, 0), result.chunks.len);
}

test "parseLLMResponse returns fallback on invalid JSON" {
    const allocator = std.testing.allocator;
    var client = try HanaRAGClient.init(allocator, HanaRAGConfig{});
    defer client.deinit();

    const result = try client.parseLLMResponse("{broken");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Error parsing LLM response.", result);
}

test "HanaRAGConfig default values" {
    const config = HanaRAGConfig{};
    try std.testing.expectEqualStrings("localhost", config.hana_host);
    try std.testing.expectEqual(@as(u16, 443), config.hana_port);
    try std.testing.expectEqual(@as(usize, 5), config.top_k);
}

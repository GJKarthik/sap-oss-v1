//! OpenAI-Compatible Search API
//! Implements the embeddings and search API in OpenAI format
//! Based on Mangle schema: sdk/mangle-sap-bdc/connectors/search.mg

const std = @import("std");
const vector_index = @import("vector_index.zig");

const log = std.log.scoped(.openai_api);

// ============================================================================
// OpenAI API Types
// ============================================================================

/// OpenAI Embeddings Create Request
/// POST /v1/embeddings
pub const EmbeddingsCreateRequest = struct {
    input: InputType,
    model: []const u8,
    encoding_format: ?[]const u8 = null, // "float" or "base64"
    dimensions: ?u32 = null, // For v3 models only
    user: ?[]const u8 = null,
    
    pub const InputType = union(enum) {
        single: []const u8,
        multiple: []const []const u8,
    };
};

/// OpenAI Embeddings Response
pub const EmbeddingsResponse = struct {
    object: []const u8 = "list",
    data: []EmbeddingObject,
    model: []const u8,
    usage: Usage,
    
    pub const EmbeddingObject = struct {
        object: []const u8 = "embedding",
        index: usize,
        embedding: []f32,
    };
    
    pub const Usage = struct {
        prompt_tokens: u32,
        total_tokens: u32,
    };
};

/// Search Request (Extended OpenAI-style)
/// POST /v1/search
pub const SearchRequest = struct {
    /// Query text (will be embedded using the model)
    query: ?[]const u8 = null,
    /// Pre-computed query embedding (array of floats)
    query_embedding: ?[]f32 = null,
    /// Index to search in
    index: ?[]const u8 = null,
    /// Number of results to return (default: 10)
    top_k: u32 = 10,
    /// Minimum similarity score threshold (0.0 to 1.0)
    min_score: f32 = 0.0,
    /// Include document content in response
    include_content: bool = true,
    /// Include metadata in response
    include_metadata: bool = true,
    /// Include embedding vectors in response
    include_vectors: bool = false,
    /// Metadata filter (JSON object)
    filter: ?[]const u8 = null,
    /// Model for embedding the query (if query text provided)
    model: []const u8 = "text-embedding-3-small",
    /// User identifier for tracking
    user: ?[]const u8 = null,
};

/// Search Response
pub const SearchResponse = struct {
    object: []const u8 = "search.results",
    data: []SearchResult,
    model: []const u8,
    index: []const u8,
    usage: ?Usage = null,
    
    pub const SearchResult = struct {
        object: []const u8 = "search.result",
        index: u32, // rank
        score: f32,
        document: Document,
    };
    
    pub const Document = struct {
        id: []const u8,
        content: ?[]const u8 = null,
        metadata: ?std.json.Value = null,
        embedding: ?[]f32 = null,
    };
    
    pub const Usage = struct {
        prompt_tokens: u32,
        total_tokens: u32,
        embedding_tokens: u32,
    };
};

/// Error response in OpenAI format
pub const ErrorResponse = struct {
    @"error": Error,
    
    pub const Error = struct {
        message: []const u8,
        @"type": []const u8,
        param: ?[]const u8 = null,
        code: ?[]const u8 = null,
    };
};

// ============================================================================
// API Handler
// ============================================================================

pub const OpenAISearchHandler = struct {
    allocator: std.mem.Allocator,
    index: *vector_index.VectorIndex,
    default_model: []const u8,
    
    pub fn init(
        allocator: std.mem.Allocator,
        index: *vector_index.VectorIndex,
        default_model: []const u8,
    ) OpenAISearchHandler {
        return .{
            .allocator = allocator,
            .index = index,
            .default_model = default_model,
        };
    }
    
    /// Handle POST /v1/search
    pub fn handleSearch(self: *OpenAISearchHandler, request_body: []const u8) ![]u8 {
        // Parse request
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, request_body, .{}) catch {
            return self.formatError("Invalid JSON in request body", "invalid_request_error", "body", null);
        };
        defer parsed.deinit();
        
        const root = parsed.value;
        
        // Extract query or query_embedding
        const query_text = if (root.object.get("query")) |q| q.string else null;
        var query_embedding: ?[]f32 = null;
        defer if (query_embedding) |e| self.allocator.free(e);
        
        if (root.object.get("query_embedding")) |qe| {
            if (qe == .array) {
                query_embedding = try self.allocator.alloc(f32, qe.array.items.len);
                for (qe.array.items, 0..) |item, i| {
                    query_embedding.?[i] = @floatCast(item.float);
                }
            }
        }
        
        // Must have either query or query_embedding
        if (query_text == null and query_embedding == null) {
            return self.formatError("Either 'query' or 'query_embedding' is required", "invalid_request_error", null, null);
        }
        
        // Extract other parameters
        const top_k: u32 = if (root.object.get("top_k")) |tk|
            @intCast(tk.integer)
        else
            10;
        
        const min_score: f32 = if (root.object.get("min_score")) |ms|
            @floatCast(ms.float)
        else
            0.0;
        
        const include_content = if (root.object.get("include_content")) |ic|
            ic.bool
        else
            true;
        
        const include_metadata = if (root.object.get("include_metadata")) |im|
            im.bool
        else
            true;
        
        const include_vectors = if (root.object.get("include_vectors")) |iv|
            iv.bool
        else
            false;
        
        const model = if (root.object.get("model")) |m| m.string else self.default_model;
        
        // If query text provided but no embedding, we need to embed it
        // For now, generate a mock embedding (in production, call NIM or local model)
        var embedding_to_use: []f32 = undefined;
        var embedding_owned = false;
        var tokens_used: u32 = 0;
        
        if (query_embedding) |qe| {
            embedding_to_use = qe;
        } else if (query_text) |text| {
            // Generate mock embedding based on text hash
            // In production, this would call the NIM client or local model
            embedding_to_use = try self.generateMockEmbedding(text);
            embedding_owned = true;
            tokens_used = @intCast(text.len / 4 + 1); // Rough token estimate
        } else {
            return self.formatError("No embedding source available", "invalid_request_error", null, null);
        }
        defer if (embedding_owned) self.allocator.free(embedding_to_use);
        
        // Perform search
        var search_response = self.index.search(
            embedding_to_use,
            top_k,
            min_score,
            include_content,
            include_metadata,
            include_vectors,
        ) catch |err| {
            return self.formatError(@errorName(err), "search_error", null, null);
        };
        defer search_response.deinit(self.allocator);
        
        // Format OpenAI-style response
        return self.formatSearchResponse(search_response, model, tokens_used);
    }
    
    /// Handle POST /v1/embeddings
    pub fn handleEmbeddings(self: *OpenAISearchHandler, request_body: []const u8) ![]u8 {
        // Parse request
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, request_body, .{}) catch {
            return self.formatError("Invalid JSON in request body", "invalid_request_error", "body", null);
        };
        defer parsed.deinit();
        
        const root = parsed.value;
        
        // Get input
        const input = root.object.get("input") orelse {
            return self.formatError("'input' is required", "invalid_request_error", "input", null);
        };
        
        const model = if (root.object.get("model")) |m| m.string else "text-embedding-3-small";
        
        // Process input(s)
        var embeddings: std.ArrayListUnmanaged(EmbeddingsResponse.EmbeddingObject) = .{};
        defer {
            for (embeddings.items) |item| {
                self.allocator.free(item.embedding);
            }
            embeddings.deinit(self.allocator);
        }
        
        var total_tokens: u32 = 0;
        
        if (input == .string) {
            const text = input.string;
            const embedding = try self.generateMockEmbedding(text);
            total_tokens = @intCast(text.len / 4 + 1);
            try embeddings.append(self.allocator, .{
                .index = 0,
                .embedding = embedding,
            });
        } else if (input == .array) {
            for (input.array.items, 0..) |item, i| {
                if (item == .string) {
                    const text = item.string;
                    const embedding = try self.generateMockEmbedding(text);
                    total_tokens += @intCast(text.len / 4 + 1);
                    try embeddings.append(self.allocator, .{
                        .index = i,
                        .embedding = embedding,
                    });
                }
            }
        } else {
            return self.formatError("'input' must be a string or array of strings", "invalid_request_error", "input", null);
        }
        
        // Format response
        return self.formatEmbeddingsResponse(embeddings.items, model, total_tokens);
    }
    
    // =========================================================================
    // Response Formatting
    // =========================================================================
    
    fn formatSearchResponse(
        self: *OpenAISearchHandler,
        response: vector_index.SearchResponse,
        model: []const u8,
        tokens_used: u32,
    ) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        errdefer buf.deinit(self.allocator);
        
        const writer = buf.writer(self.allocator);
        
        try writer.writeAll("{\"object\":\"search.results\",\"data\":[");
        
        for (response.results, 0..) |result, i| {
            if (i > 0) try writer.writeAll(",");
            
            try writer.writeAll("{\"object\":\"search.result\",\"index\":");
            try std.fmt.format(writer, "{}", .{result.rank});
            try writer.writeAll(",\"score\":");
            try std.fmt.format(writer, "{d:.6}", .{result.score});
            try writer.writeAll(",\"document\":{\"id\":\"");
            try writer.writeAll(result.doc_id);
            try writer.writeAll("\"");
            
            if (result.content) |content| {
                try writer.writeAll(",\"content\":\"");
                // Escape JSON string
                for (content) |c| {
                    switch (c) {
                        '"' => try writer.writeAll("\\\""),
                        '\\' => try writer.writeAll("\\\\"),
                        '\n' => try writer.writeAll("\\n"),
                        '\r' => try writer.writeAll("\\r"),
                        '\t' => try writer.writeAll("\\t"),
                        else => try writer.writeByte(c),
                    }
                }
                try writer.writeAll("\"");
            }
            
            if (result.metadata) |metadata| {
                try writer.writeAll(",\"metadata\":");
                try writer.writeAll(metadata);
            }
            
            try writer.writeAll("}}");
        }
        
        try writer.writeAll("],\"model\":\"");
        try writer.writeAll(model);
        try writer.writeAll("\",\"index\":\"");
        try writer.writeAll(self.index.config.index_id);
        try writer.writeAll("\"");
        
        if (tokens_used > 0) {
            try writer.writeAll(",\"usage\":{\"prompt_tokens\":");
            try std.fmt.format(writer, "{}", .{tokens_used});
            try writer.writeAll(",\"total_tokens\":");
            try std.fmt.format(writer, "{}", .{tokens_used});
            try writer.writeAll(",\"embedding_tokens\":");
            try std.fmt.format(writer, "{}", .{tokens_used});
            try writer.writeAll("}");
        }
        
        try writer.writeAll("}");
        
        return buf.toOwnedSlice(self.allocator);
    }
    
    fn formatEmbeddingsResponse(
        self: *OpenAISearchHandler,
        embeddings: []EmbeddingsResponse.EmbeddingObject,
        model: []const u8,
        total_tokens: u32,
    ) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        errdefer buf.deinit(self.allocator);
        
        const writer = buf.writer(self.allocator);
        
        try writer.writeAll("{\"object\":\"list\",\"data\":[");
        
        for (embeddings, 0..) |emb, i| {
            if (i > 0) try writer.writeAll(",");
            
            try writer.writeAll("{\"object\":\"embedding\",\"index\":");
            try std.fmt.format(writer, "{}", .{emb.index});
            try writer.writeAll(",\"embedding\":[");
            
            // Write first 10 dimensions for brevity (or all if less)
            const dims_to_write = @min(emb.embedding.len, 10);
            for (0..dims_to_write) |j| {
                if (j > 0) try writer.writeAll(",");
                try std.fmt.format(writer, "{d:.6}", .{emb.embedding[j]});
            }
            if (dims_to_write < emb.embedding.len) {
                try writer.writeAll(",..."); // Indicate truncation
            }
            
            try writer.writeAll("]}");
        }
        
        try writer.writeAll("],\"model\":\"");
        try writer.writeAll(model);
        try writer.writeAll("\",\"usage\":{\"prompt_tokens\":");
        try std.fmt.format(writer, "{}", .{total_tokens});
        try writer.writeAll(",\"total_tokens\":");
        try std.fmt.format(writer, "{}", .{total_tokens});
        try writer.writeAll("}}");
        
        return buf.toOwnedSlice(self.allocator);
    }
    
    fn formatError(
        self: *OpenAISearchHandler,
        message: []const u8,
        error_type: []const u8,
        param: ?[]const u8,
        code: ?[]const u8,
    ) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        errdefer buf.deinit(self.allocator);
        
        const writer = buf.writer(self.allocator);
        
        try writer.writeAll("{\"error\":{\"message\":\"");
        try writer.writeAll(message);
        try writer.writeAll("\",\"type\":\"");
        try writer.writeAll(error_type);
        try writer.writeAll("\"");
        
        if (param) |p| {
            try writer.writeAll(",\"param\":\"");
            try writer.writeAll(p);
            try writer.writeAll("\"");
        }
        
        if (code) |c| {
            try writer.writeAll(",\"code\":\"");
            try writer.writeAll(c);
            try writer.writeAll("\"");
        }
        
        try writer.writeAll("}}");
        
        return buf.toOwnedSlice(self.allocator);
    }
    
    // =========================================================================
    // Mock Embedding Generation
    // =========================================================================
    
    /// Generate a mock embedding for testing
    /// In production, this would call NIM or a local model
    fn generateMockEmbedding(self: *OpenAISearchHandler, text: []const u8) ![]f32 {
        const dims = self.index.config.dimensions;
        var embedding = try self.allocator.alloc(f32, dims);
        
        // Generate deterministic "embedding" based on text hash
        // This ensures same text produces same embedding
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(text);
        const seed = hasher.final();
        
        var rng = std.Random.DefaultPrng.init(seed);
        const random = rng.random();
        
        // Generate random unit vector
        var norm: f32 = 0.0;
        for (0..dims) |i| {
            const val = random.floatNorm(f32);
            embedding[i] = val;
            norm += val * val;
        }
        
        // Normalize to unit length
        norm = @sqrt(norm);
        if (norm > 0) {
            for (0..dims) |i| {
                embedding[i] /= norm;
            }
        }
        
        return embedding;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "OpenAISearchHandler formatError" {
    const allocator = std.testing.allocator;
    
    // Create a minimal index for testing
    const index = try vector_index.VectorIndex.init(allocator, .{
        .index_id = "test",
        .name = "Test",
        .dimensions = 4,
    }, null);
    defer index.deinit();
    
    var handler = OpenAISearchHandler.init(allocator, index, "text-embedding-3-small");
    
    const error_json = try handler.formatError("Test error", "test_error", null, null);
    defer allocator.free(error_json);
    
    try std.testing.expect(std.mem.indexOf(u8, error_json, "Test error") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_json, "test_error") != null);
}

test "generateMockEmbedding produces consistent results" {
    const allocator = std.testing.allocator;
    
    const index = try vector_index.VectorIndex.init(allocator, .{
        .index_id = "test",
        .name = "Test",
        .dimensions = 16,
    }, null);
    defer index.deinit();
    
    var handler = OpenAISearchHandler.init(allocator, index, "text-embedding-3-small");
    
    const emb1 = try handler.generateMockEmbedding("hello world");
    defer allocator.free(emb1);
    
    const emb2 = try handler.generateMockEmbedding("hello world");
    defer allocator.free(emb2);
    
    // Same text should produce same embedding
    for (emb1, emb2) |a, b| {
        try std.testing.expectApproxEqAbs(a, b, 0.0001);
    }
}
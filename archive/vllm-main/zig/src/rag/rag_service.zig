// ============================================================================
// RAG Service - Uses SDK Connector Types
// ============================================================================
// Implements RAG (Retrieval-Augmented Generation) using:
//   - connector_types.zig for type definitions
//   - hana_connector.zig for vector storage
//   - llm/backend.zig for embeddings and generation

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../gen/connector_types.zig");
const hana = @import("../sap/hana_connector.zig");
const hana_rag = @import("../sap/hana_rag.zig");
const toon = @import("../toon/toon.zig");

// Re-export types for convenience
pub const RagDocument = types.RagDocument;
pub const RagChunk = types.RagChunk;
pub const RagQuery = types.RagQuery;
pub const RagResult = types.RagResult;
pub const HanaVectorSearch = types.HanaVectorSearch;
pub const HanaVectorInsert = types.HanaVectorInsert;
pub const LlmEmbeddingRequest = types.LlmEmbeddingRequest;

pub const RagServiceConfig = struct {
    service_id: []const u8,
    index_id: []const u8,
    embedding_model: []const u8,
    embedding_dimensions: i32,
    default_k: i32,
    similarity_threshold: f64,
    max_context_tokens: i32,
    chunk_size: i32,
    chunk_overlap: i32,
};

pub const RagService = struct {
    allocator: Allocator,
    config: RagServiceConfig,
    hana_conn: ?*hana.HanaConnection,
    toon_store: *toon.ToonStore,

    const Self = @This();

    pub fn init(allocator: Allocator, config: RagServiceConfig, toon_store: *toon.ToonStore) Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .hana_conn = null,
            .toon_store = toon_store,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.hana_conn) |conn| {
            conn.disconnect();
        }
    }

    // ========================================================================
    // Document Indexing
    // ========================================================================

    /// Index a document by chunking, embedding, and storing vectors
    pub fn indexDocument(
        self: *Self,
        doc_id: []const u8,
        source: []const u8,
        content: []const u8,
        doc_type: RagDocument.DocType,
        embed_fn: *const fn ([]const u8) anyerror![]f32,
    ) !RagDocument {
        // 1. Chunk the document
        const chunks = try self.chunkDocument(content);
        defer {
            for (chunks) |chunk| {
                self.allocator.free(chunk);
            }
            self.allocator.free(chunks);
        }

        var total_tokens: i32 = 0;
        var chunk_count: i32 = 0;

        // 2. For each chunk, embed and store
        for (chunks, 0..) |chunk_text, idx| {
            const chunk_id = try std.fmt.allocPrint(self.allocator, "{s}_chunk_{d}", .{ doc_id, idx });
            defer self.allocator.free(chunk_id);

            // Generate embedding
            const embedding = try embed_fn(chunk_text);
            defer self.allocator.free(embedding);

            // Store embedding in TOON
            const embedding_bytes = std.mem.sliceAsBytes(embedding);
            const toon_ptr = try self.toon_store.put("embeddings", embedding_bytes);

            // Store in HANA vector
            const insert_req = HanaVectorInsert{
                .request_id = try self.generateRequestId(),
                .service_id = self.config.service_id,
                .schema = "PRIVATELLM_RAG",
                .table = "RAG_EMBEDDINGS",
                .record_id = chunk_id,
                .vector_data = toon_ptr,
                .metadata = try self.serializeChunkMetadata(doc_id, idx, chunk_text),
                .requested_at = std.time.milliTimestamp(),
            };

            try self.executeVectorInsert(insert_req);

            total_tokens += @intCast(chunk_text.len / 4); // Rough token estimate
            chunk_count += 1;
        }

        return RagDocument{
            .doc_id = doc_id,
            .source = source,
            .doc_type = doc_type,
            .chunk_count = chunk_count,
            .total_tokens = total_tokens,
            .indexed_at = std.time.milliTimestamp(),
        };
    }

    /// Chunk document into overlapping segments
    fn chunkDocument(self: *Self, content: []const u8) ![][]const u8 {
        var chunks = std.ArrayList([]const u8){};
        errdefer chunks.deinit();

        const chunk_size: usize = @intCast(self.config.chunk_size);
        const overlap: usize = @intCast(self.config.chunk_overlap);

        var start: usize = 0;
        while (start < content.len) {
            const end = @min(start + chunk_size, content.len);
            const chunk = try self.allocator.dupe(u8, content[start..end]);
            try chunks.append(chunk);

            if (end >= content.len) break;
            start = end - overlap;
        }

        return chunks.toOwnedSlice();
    }

    // ========================================================================
    // Query / Retrieval
    // ========================================================================

    /// Execute RAG query: embed query, search vectors, return context
    pub fn query(
        self: *Self,
        user_query: []const u8,
        k: ?i32,
        threshold: ?f64,
        embed_fn: *const fn ([]const u8) anyerror![]f32,
    ) !RagResult {
        const query_id = try self.generateRequestId();
        const effective_k = k orelse self.config.default_k;
        const effective_threshold = threshold orelse self.config.similarity_threshold;

        // 1. Embed the query
        const query_embedding = try embed_fn(user_query);
        defer self.allocator.free(query_embedding);

        // Store query embedding in TOON
        const embedding_bytes = std.mem.sliceAsBytes(query_embedding);
        const query_toon_ptr = try self.toon_store.put("query_embeddings", embedding_bytes);

        // 2. Search HANA vector index
        const search_start = std.time.milliTimestamp();
        const search_req = HanaVectorSearch{
            .search_id = query_id,
            .index_id = self.config.index_id,
            .query_vector_ref = query_toon_ptr,
            .k = effective_k,
            .filter = null,
            .executed_at = search_start,
        };

        const search_results = try self.executeVectorSearch(search_req);
        const retrieval_ms = std.time.milliTimestamp() - search_start;

        // 3. Filter by threshold and build context
        var context_builder = std.ArrayList(u8){};
        defer context_builder.deinit();
        var total_tokens: i32 = 0;

        // Parse results and concatenate text
        var results_array = std.ArrayList([]const u8){};
        defer results_array.deinit();

        // Parse JSON results (simplified - in production use proper JSON parser)
        for (search_results.items) |result| {
            if (result.distance <= effective_threshold) {
                try results_array.append(result.chunk_id);
                try context_builder.appendSlice(result.text);
                try context_builder.appendSlice("\n\n");
                total_tokens += result.token_count;

                // Stop if we exceed max context
                if (total_tokens >= self.config.max_context_tokens) break;
            }
        }

        return RagResult{
            .query_id = query_id,
            .retrieved_chunks = try types.serializeJson([][]const u8, results_array.items, self.allocator),
            .context_text = try context_builder.toOwnedSlice(),
            .total_tokens = total_tokens,
            .retrieval_ms = retrieval_ms,
        };
    }

    /// Build augmented prompt with RAG context
    pub fn buildAugmentedPrompt(
        self: *Self,
        user_query: []const u8,
        rag_result: RagResult,
    ) ![]const u8 {
        const template =
            \\Use the following context to answer the user's question.
            \\If the context doesn't contain relevant information, say so.
            \\
            \\Context:
            \\{s}
            \\
            \\User Question: {s}
            \\
            \\Answer:
        ;

        return std.fmt.allocPrint(self.allocator, template, .{
            rag_result.context_text,
            user_query,
        });
    }

    // ========================================================================
    // HANA Vector Operations (delegates to hana_rag.zig)
    // ========================================================================

    fn executeVectorInsert(self: *Self, req: HanaVectorInsert) !void {
        _ = self;
        // Delegate to hana_rag module
        try hana_rag.insertVector(req);
    }

    fn executeVectorSearch(self: *Self, req: HanaVectorSearch) !SearchResults {
        _ = self;
        // Delegate to hana_rag module
        return try hana_rag.searchVectors(req);
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    fn generateRequestId(self: *Self) ![]const u8 {
        var buf: [32]u8 = undefined;
        const random_bytes = try std.crypto.random.bytes(buf[0..16]);
        return std.fmt.allocPrint(self.allocator, "rag_{x}", .{std.fmt.fmtSliceHexLower(random_bytes)});
    }

    fn serializeChunkMetadata(
        self: *Self,
        doc_id: []const u8,
        chunk_index: usize,
        text: []const u8,
    ) ![]const u8 {
        const metadata = .{
            .doc_id = doc_id,
            .chunk_index = chunk_index,
            .text = text[0..@min(text.len, 500)], // Truncate for metadata
            .token_count = text.len / 4,
        };
        return types.serializeJson(@TypeOf(metadata), metadata, self.allocator);
    }
};

// ============================================================================
// Search Result Types
// ============================================================================

const SearchResult = struct {
    chunk_id: []const u8,
    distance: f64,
    text: []const u8,
    token_count: i32,
};

const SearchResults = struct {
    items: []SearchResult,
};

// ============================================================================
// Tests
// ============================================================================

test "RagService chunk document" {
    const allocator = std.testing.allocator;

    var toon_store = try toon.ToonStore.init(allocator);
    defer toon_store.deinit();

    const config = RagServiceConfig{
        .service_id = "test",
        .index_id = "test_idx",
        .embedding_model = "all-MiniLM-L6-v2",
        .embedding_dimensions = 384,
        .default_k = 5,
        .similarity_threshold = 0.7,
        .max_context_tokens = 2000,
        .chunk_size = 100,
        .chunk_overlap = 20,
    };

    var service = RagService.init(allocator, config, &toon_store);
    defer service.deinit();

    const content = "This is a test document with some content that should be chunked into multiple pieces for vector storage and retrieval.";
    const chunks = try service.chunkDocument(content);
    defer {
        for (chunks) |chunk| {
            allocator.free(chunk);
        }
        allocator.free(chunks);
    }

    try std.testing.expect(chunks.len >= 1);
}
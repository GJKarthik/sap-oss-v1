//! Vector Search Index
//! Implements GPU-accelerated vector similarity search with OpenAI-compatible API
//! Based on Mangle schema: sdk/mangle-sap-bdc/connectors/search.mg

const std = @import("std");

const log = std.log.scoped(.vector_index);

// GPU context type (opaque - set by caller)
pub const GpuContext = *anyopaque;

// ============================================================================
// Configuration
// ============================================================================

pub const DistanceMetric = enum {
    cosine,
    euclidean,
    dot_product,
    
    pub fn fromString(s: []const u8) ?DistanceMetric {
        if (std.mem.eql(u8, s, "cosine")) return .cosine;
        if (std.mem.eql(u8, s, "euclidean")) return .euclidean;
        if (std.mem.eql(u8, s, "dot_product")) return .dot_product;
        return null;
    }
    
    pub fn toString(self: DistanceMetric) []const u8 {
        return switch (self) {
            .cosine => "cosine",
            .euclidean => "euclidean",
            .dot_product => "dot_product",
        };
    }
};

pub const IndexConfig = struct {
    /// Unique index identifier
    index_id: []const u8,
    /// Human-readable name
    name: []const u8,
    /// Embedding model used
    embedding_model: []const u8 = "text-embedding-3-small",
    /// Embedding dimensions
    dimensions: u32 = 1536,
    /// Distance metric for similarity
    distance_metric: DistanceMetric = .cosine,
    /// Maximum number of vectors
    max_elements: u64 = 1_000_000,
    /// HNSW M parameter (connections per node)
    hnsw_m: u16 = 16,
    /// HNSW ef_construction (build-time accuracy)
    hnsw_ef_construction: u16 = 200,
};

// ============================================================================
// Document Storage
// ============================================================================

pub const Document = struct {
    doc_id: []const u8,
    content: []const u8,
    metadata: ?[]const u8,
    embedding: []f32,
    indexed_at: i64,
    
    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        allocator.free(self.doc_id);
        allocator.free(self.content);
        if (self.metadata) |m| allocator.free(m);
        allocator.free(self.embedding);
    }
};

pub const SearchResult = struct {
    rank: u32,
    doc_id: []const u8,
    score: f32,
    content: ?[]const u8,
    metadata: ?[]const u8,
    embedding: ?[]f32,
};

// ============================================================================
// Vector Index
// ============================================================================

pub const VectorIndex = struct {
    allocator: std.mem.Allocator,
    config: IndexConfig,
    
    // Document storage
    documents: std.StringHashMap(Document),
    doc_count: std.atomic.Value(u64),
    
    // Vector storage for GPU operations
    vectors: std.ArrayListUnmanaged(f32),
    doc_ids: std.ArrayListUnmanaged([]const u8),
    
    // GPU context for accelerated search
    gpu_context: ?GpuContext,
    
    // Statistics
    total_searches: std.atomic.Value(u64),
    total_search_time_ns: std.atomic.Value(u64),
    
    // Index state
    created_at: i64,
    last_modified: i64,
    
    pub fn init(allocator: std.mem.Allocator, config: IndexConfig, gpu_ctx: ?GpuContext) !*VectorIndex {
        const index = try allocator.create(VectorIndex);
        const now = std.time.milliTimestamp();
        
        index.* = .{
            .allocator = allocator,
            .config = config,
            .documents = std.StringHashMap(Document).init(allocator),
            .doc_count = std.atomic.Value(u64).init(0),
            .vectors = .{},
            .doc_ids = .{},
            .gpu_context = gpu_ctx,
            .total_searches = std.atomic.Value(u64).init(0),
            .total_search_time_ns = std.atomic.Value(u64).init(0),
            .created_at = now,
            .last_modified = now,
        };
        
        log.info("Vector index created:", .{});
        log.info("  ID: {s}", .{config.index_id});
        log.info("  Dimensions: {}", .{config.dimensions});
        log.info("  Distance Metric: {s}", .{config.distance_metric.toString()});
        log.info("  Max Elements: {}", .{config.max_elements});
        
        return index;
    }
    
    pub fn deinit(self: *VectorIndex) void {
        // Free all documents
        var doc_iter = self.documents.iterator();
        while (doc_iter.next()) |entry| {
            var doc = entry.value_ptr.*;
            doc.deinit(self.allocator);
        }
        self.documents.deinit();
        
        self.vectors.deinit(self.allocator);
        
        // Free doc_ids
        for (self.doc_ids.items) |id| {
            self.allocator.free(id);
        }
        self.doc_ids.deinit(self.allocator);
        
        self.allocator.destroy(self);
    }
    
    /// Add a document with its embedding to the index
    pub fn addDocument(
        self: *VectorIndex,
        doc_id: []const u8,
        content: []const u8,
        metadata: ?[]const u8,
        embedding: []const f32,
    ) !void {
        if (embedding.len != self.config.dimensions) {
            return error.DimensionMismatch;
        }
        
        if (self.doc_count.load(.acquire) >= self.config.max_elements) {
            return error.IndexFull;
        }
        
        const now = std.time.milliTimestamp();
        
        // Copy data
        const doc_id_copy = try self.allocator.dupe(u8, doc_id);
        errdefer self.allocator.free(doc_id_copy);
        
        const content_copy = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(content_copy);
        
        const metadata_copy = if (metadata) |m| try self.allocator.dupe(u8, m) else null;
        errdefer if (metadata_copy) |m| self.allocator.free(m);
        
        const embedding_copy = try self.allocator.dupe(f32, embedding);
        errdefer self.allocator.free(embedding_copy);
        
        const doc = Document{
            .doc_id = doc_id_copy,
            .content = content_copy,
            .metadata = metadata_copy,
            .embedding = embedding_copy,
            .indexed_at = now,
        };
        
        // Add to document store
        try self.documents.put(doc_id_copy, doc);
        
        // Add to vector store for batch operations
        try self.vectors.appendSlice(self.allocator, embedding_copy);
        try self.doc_ids.append(self.allocator, try self.allocator.dupe(u8, doc_id_copy));
        
        _ = self.doc_count.fetchAdd(1, .monotonic);
        self.last_modified = now;
    }
    
    /// Search for similar documents
    pub fn search(
        self: *VectorIndex,
        query_embedding: []const f32,
        top_k: u32,
        min_score: f32,
        include_content: bool,
        include_metadata: bool,
        include_vectors: bool,
    ) !SearchResponse {
        const start_time = std.time.nanoTimestamp();
        
        if (query_embedding.len != self.config.dimensions) {
            return error.DimensionMismatch;
        }
        
        const doc_count = self.doc_count.load(.acquire);
        if (doc_count == 0) {
            return SearchResponse{
                .results = &[_]SearchResult{},
                .total_results = 0,
                .duration_ms = 0,
            };
        }
        
        // Compute similarities
        var scores = try self.allocator.alloc(f32, doc_count);
        defer self.allocator.free(scores);
        
        var indices = try self.allocator.alloc(usize, doc_count);
        defer self.allocator.free(indices);
        
        // Calculate similarity scores
        for (0..doc_count) |i| {
            const start = i * self.config.dimensions;
            const end = start + self.config.dimensions;
            const doc_embedding = self.vectors.items[start..end];
            
            scores[i] = self.computeSimilarity(query_embedding, doc_embedding);
            indices[i] = i;
        }
        
        // Sort by score (descending)
        std.mem.sort(usize, indices, ScoreContext{ .scores = scores }, compareByScore);
        
        // Build results
        const result_count = @min(top_k, @as(u32, @intCast(doc_count)));
        var results = try self.allocator.alloc(SearchResult, result_count);
        var actual_count: usize = 0;
        
        for (0..result_count) |rank| {
            const idx = indices[rank];
            const score = scores[idx];
            
            if (score < min_score) break;
            
            const doc_id = self.doc_ids.items[idx];
            const doc = self.documents.get(doc_id) orelse continue;
            
            results[actual_count] = SearchResult{
                .rank = @intCast(rank + 1),
                .doc_id = doc_id,
                .score = score,
                .content = if (include_content) doc.content else null,
                .metadata = if (include_metadata) doc.metadata else null,
                .embedding = if (include_vectors) doc.embedding else null,
            };
            actual_count += 1;
        }
        
        const end_time = std.time.nanoTimestamp();
        const duration_ns: u64 = @intCast(end_time - start_time);
        
        _ = self.total_searches.fetchAdd(1, .monotonic);
        _ = self.total_search_time_ns.fetchAdd(duration_ns, .monotonic);
        
        return SearchResponse{
            .results = results[0..actual_count],
            .total_results = @intCast(actual_count),
            .duration_ms = duration_ns / std.time.ns_per_ms,
        };
    }
    
    fn computeSimilarity(self: *VectorIndex, a: []const f32, b: []const f32) f32 {
        return switch (self.config.distance_metric) {
            .cosine => cosineSimilarity(a, b),
            .dot_product => dotProduct(a, b),
            .euclidean => 1.0 / (1.0 + euclideanDistance(a, b)),
        };
    }
    
    /// Get index statistics
    pub fn getStats(self: *const VectorIndex) IndexStats {
        const total_searches = self.total_searches.load(.acquire);
        const total_time_ns = self.total_search_time_ns.load(.acquire);
        const avg_search_ms: f64 = if (total_searches > 0)
            @as(f64, @floatFromInt(total_time_ns)) / @as(f64, @floatFromInt(total_searches)) / 1_000_000.0
        else
            0.0;
        
        return IndexStats{
            .index_id = self.config.index_id,
            .document_count = self.doc_count.load(.acquire),
            .dimensions = self.config.dimensions,
            .distance_metric = self.config.distance_metric.toString(),
            .storage_bytes = self.vectors.items.len * @sizeOf(f32),
            .total_searches = total_searches,
            .avg_search_time_ms = avg_search_ms,
            .created_at = self.created_at,
            .last_modified = self.last_modified,
        };
    }
};

// ============================================================================
// Response Types
// ============================================================================

pub const SearchResponse = struct {
    results: []SearchResult,
    total_results: u32,
    duration_ms: u64,
    
    pub fn deinit(self: *SearchResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.results);
    }
};

pub const IndexStats = struct {
    index_id: []const u8,
    document_count: u64,
    dimensions: u32,
    distance_metric: []const u8,
    storage_bytes: usize,
    total_searches: u64,
    avg_search_time_ms: f64,
    created_at: i64,
    last_modified: i64,
};

// ============================================================================
// Math Functions
// ============================================================================

fn cosineSimilarity(a: []const f32, b: []const f32) f32 {
    var dot: f32 = 0.0;
    var norm_a: f32 = 0.0;
    var norm_b: f32 = 0.0;
    
    for (a, b) |va, vb| {
        dot += va * vb;
        norm_a += va * va;
        norm_b += vb * vb;
    }
    
    const denom = @sqrt(norm_a) * @sqrt(norm_b);
    if (denom == 0.0) return 0.0;
    return dot / denom;
}

fn dotProduct(a: []const f32, b: []const f32) f32 {
    var result: f32 = 0.0;
    for (a, b) |va, vb| {
        result += va * vb;
    }
    return result;
}

fn euclideanDistance(a: []const f32, b: []const f32) f32 {
    var sum: f32 = 0.0;
    for (a, b) |va, vb| {
        const diff = va - vb;
        sum += diff * diff;
    }
    return @sqrt(sum);
}

// ============================================================================
// Sorting Helper
// ============================================================================

const ScoreContext = struct {
    scores: []f32,
};

fn compareByScore(context: ScoreContext, a: usize, b: usize) bool {
    // Descending order (higher scores first)
    return context.scores[a] > context.scores[b];
}

// ============================================================================
// Tests
// ============================================================================

test "VectorIndex basic operations" {
    const allocator = std.testing.allocator;
    
    const index = try VectorIndex.init(allocator, .{
        .index_id = "test-index",
        .name = "Test Index",
        .dimensions = 4,
        .distance_metric = .cosine,
        .max_elements = 1000,
    }, null);
    defer index.deinit();
    
    // Add documents
    const doc1_embedding = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    try index.addDocument("doc1", "First document", null, &doc1_embedding);
    
    const doc2_embedding = [_]f32{ 0.0, 1.0, 0.0, 0.0 };
    try index.addDocument("doc2", "Second document", "{\"tag\":\"test\"}", &doc2_embedding);
    
    const doc3_embedding = [_]f32{ 0.9, 0.1, 0.0, 0.0 };
    try index.addDocument("doc3", "Third document", null, &doc3_embedding);
    
    try std.testing.expectEqual(@as(u64, 3), index.doc_count.load(.acquire));
    
    // Search for similar to doc1
    const query = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    var response = try index.search(&query, 10, 0.0, true, true, false);
    defer response.deinit(allocator);
    
    try std.testing.expectEqual(@as(u32, 3), response.total_results);
    try std.testing.expectEqualStrings("doc1", response.results[0].doc_id);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), response.results[0].score, 0.001);
}

test "cosineSimilarity" {
    const a = [_]f32{ 1.0, 0.0, 0.0 };
    const b = [_]f32{ 1.0, 0.0, 0.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cosineSimilarity(&a, &b), 0.001);
    
    const c = [_]f32{ 0.0, 1.0, 0.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cosineSimilarity(&a, &c), 0.001);
}

test "euclideanDistance" {
    const a = [_]f32{ 0.0, 0.0 };
    const b = [_]f32{ 3.0, 4.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), euclideanDistance(&a, &b), 0.001);
}

test "DistanceMetric fromString" {
    try std.testing.expect(DistanceMetric.fromString("cosine") == .cosine);
    try std.testing.expect(DistanceMetric.fromString("euclidean") == .euclidean);
    try std.testing.expect(DistanceMetric.fromString("dot_product") == .dot_product);
    try std.testing.expect(DistanceMetric.fromString("invalid") == null);
}
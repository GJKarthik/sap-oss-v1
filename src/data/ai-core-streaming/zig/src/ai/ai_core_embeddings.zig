//! BDC AIPrompt Streaming - SAP AI Core Embeddings Integration
//! Real-time embedding generation using SAP AI Core Foundation Models

const std = @import("std");
const xsuaa = @import("../auth/xsuaa.zig");
const destination = @import("../btp/destination.zig");

const log = std.log.scoped(.ai_core);

// ============================================================================
// AI Core Configuration
// ============================================================================

pub const AICoreConfig = struct {
    /// AI Core API base URL
    api_url: []const u8 = "",
    /// Resource group
    resource_group: []const u8 = "default",
    /// Authentication
    client_id: []const u8 = "",
    client_secret: []const u8 = "",
    token_url: []const u8 = "",
    /// Model configuration
    embedding_model: []const u8 = "text-embedding-ada-002",
    embedding_dimension: u32 = 1536,
    /// Rate limiting
    max_requests_per_minute: u32 = 1000,
    max_tokens_per_request: u32 = 8000,
    /// Batching
    batch_size: u32 = 100,
    batch_timeout_ms: u32 = 100,
    /// Retry configuration
    max_retries: u32 = 3,
    retry_delay_ms: u32 = 1000,
};

// ============================================================================
// Embedding Models
// ============================================================================

pub const EmbeddingModel = enum {
    /// OpenAI text-embedding-ada-002 (1536 dimensions)
    TextEmbeddingAda002,
    /// Azure OpenAI embeddings
    AzureOpenAIEmbedding,
    /// BGE-large-en-v1.5 (1024 dimensions)
    BgeLargeEn,
    /// E5-large (1024 dimensions)
    E5Large,
    /// E5-small (384 dimensions)
    E5Small,
    /// GTE-large (1024 dimensions)
    GteLarge,
    /// Custom model
    Custom,

    pub fn getDimension(self: EmbeddingModel) u32 {
        return switch (self) {
            .TextEmbeddingAda002 => 1536,
            .AzureOpenAIEmbedding => 1536,
            .BgeLargeEn => 1024,
            .E5Large => 1024,
            .E5Small => 384,
            .GteLarge => 1024,
            .Custom => 768, // Default
        };
    }

    pub fn getMaxTokens(self: EmbeddingModel) u32 {
        return switch (self) {
            .TextEmbeddingAda002 => 8191,
            .AzureOpenAIEmbedding => 8191,
            .BgeLargeEn => 512,
            .E5Large => 512,
            .E5Small => 512,
            .GteLarge => 512,
            .Custom => 512,
        };
    }

    pub fn fromString(s: []const u8) EmbeddingModel {
        if (std.mem.eql(u8, s, "text-embedding-ada-002")) return .TextEmbeddingAda002;
        if (std.mem.eql(u8, s, "azure-openai-embedding")) return .AzureOpenAIEmbedding;
        if (std.mem.eql(u8, s, "bge-large-en-v1.5")) return .BgeLargeEn;
        if (std.mem.eql(u8, s, "e5-large")) return .E5Large;
        if (std.mem.eql(u8, s, "e5-small")) return .E5Small;
        if (std.mem.eql(u8, s, "gte-large")) return .GteLarge;
        return .Custom;
    }
};

// ============================================================================
// Embedding Request/Response
// ============================================================================

pub const EmbeddingRequest = struct {
    texts: []const []const u8,
    model: EmbeddingModel,
    truncate: bool = true,
    normalize: bool = true,
};

pub const EmbeddingResponse = struct {
    embeddings: []Embedding,
    model: []const u8,
    usage: Usage,
    latency_ms: u32,
};

pub const Embedding = struct {
    index: u32,
    vector: []f32,
    tokens_used: u32,
};

pub const Usage = struct {
    prompt_tokens: u32,
    total_tokens: u32,
};

// ============================================================================
// AI Core Client
// ============================================================================

pub const AICoreClient = struct {
    allocator: std.mem.Allocator,
    config: AICoreConfig,
    xsuaa_client: ?*xsuaa.XsuaaClient,
    access_token: ?[]const u8,
    token_expires_at: i64,

    // Rate limiting
    requests_this_minute: u32,
    minute_start: i64,

    // Stats
    total_requests: std.atomic.Value(u64),
    total_embeddings: std.atomic.Value(u64),
    total_tokens: std.atomic.Value(u64),
    total_errors: std.atomic.Value(u64),
    total_latency_ms: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, config: AICoreConfig) AICoreClient {
        return .{
            .allocator = allocator,
            .config = config,
            .xsuaa_client = null,
            .access_token = null,
            .token_expires_at = 0,
            .requests_this_minute = 0,
            .minute_start = 0,
            .total_requests = std.atomic.Value(u64).init(0),
            .total_embeddings = std.atomic.Value(u64).init(0),
            .total_tokens = std.atomic.Value(u64).init(0),
            .total_errors = std.atomic.Value(u64).init(0),
            .total_latency_ms = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *AICoreClient) void {
        _ = self;
    }

    /// Refresh OAuth2 access token
    fn refreshToken(self: *AICoreClient) !void {
        if (self.token_expires_at > std.time.timestamp() + 300) {
            return; // Token still valid
        }

        log.info("Refreshing AI Core access token", .{});

        // In production: make OAuth2 client_credentials request
        self.access_token = "mock-ai-core-token";
        self.token_expires_at = std.time.timestamp() + 43200;
    }

    /// Check rate limits
    fn checkRateLimit(self: *AICoreClient) !void {
        const now = std.time.timestamp();
        const minute = @divFloor(now, 60);

        if (minute != self.minute_start) {
            self.minute_start = minute;
            self.requests_this_minute = 0;
        }

        if (self.requests_this_minute >= self.config.max_requests_per_minute) {
            return error.RateLimitExceeded;
        }

        self.requests_this_minute += 1;
    }

    /// Generate embeddings for a batch of texts
    pub fn embed(self: *AICoreClient, request: EmbeddingRequest) !EmbeddingResponse {
        try self.refreshToken();
        try self.checkRateLimit();

        const start_time = std.time.milliTimestamp();
        _ = self.total_requests.fetchAdd(1, .monotonic);

        log.debug("Generating embeddings for {} texts using {s}", .{ request.texts.len, @tagName(request.model) });

        // Build AI Core API request
        // POST /v2/inference/deployments/{deployment}/embeddings
        const dimension = request.model.getDimension();

        var embeddings = try self.allocator.alloc(Embedding, request.texts.len);
        var total_tokens: u32 = 0;

        for (request.texts, 0..) |text, i| {
            // In production: call AI Core API
            // For now: generate mock embedding
            var vector = try self.allocator.alloc(f32, dimension);

            // Mock: deterministic embedding based on text hash
            var hash: u64 = 0;
            for (text) |c| {
                hash = hash *% 31 +% c;
            }

            for (vector, 0..) |*v, j| {
                const seed = hash +% @as(u64, @intCast(j));
                v.* = @as(f32, @floatFromInt(seed % 1000)) / 1000.0 - 0.5;
            }

            // Normalize if requested
            if (request.normalize) {
                var norm: f32 = 0;
                for (vector) |v| {
                    norm += v * v;
                }
                norm = @sqrt(norm);
                if (norm > 0) {
                    for (vector) |*v| {
                        v.* /= norm;
                    }
                }
            }

            const tokens = @as(u32, @intCast(@min(text.len / 4, request.model.getMaxTokens())));
            total_tokens += tokens;

            embeddings[i] = .{
                .index = @intCast(i),
                .vector = vector,
                .tokens_used = tokens,
            };
        }

        const latency = @as(u32, @intCast(std.time.milliTimestamp() - start_time));

        _ = self.total_embeddings.fetchAdd(@intCast(request.texts.len), .monotonic);
        _ = self.total_tokens.fetchAdd(total_tokens, .monotonic);
        _ = self.total_latency_ms.fetchAdd(latency, .monotonic);

        return .{
            .embeddings = embeddings,
            .model = @tagName(request.model),
            .usage = .{
                .prompt_tokens = total_tokens,
                .total_tokens = total_tokens,
            },
            .latency_ms = latency,
        };
    }

    /// Generate embedding for single text
    pub fn embedSingle(self: *AICoreClient, text: []const u8, model: EmbeddingModel) ![]f32 {
        const texts = [_][]const u8{text};
        const response = try self.embed(.{
            .texts = &texts,
            .model = model,
        });

        if (response.embeddings.len == 0) {
            return error.NoEmbeddingGenerated;
        }

        return response.embeddings[0].vector;
    }

    /// Get client statistics
    pub fn getStats(self: *AICoreClient) AICoreStats {
        const total_requests = self.total_requests.load(.monotonic);
        const total_latency = self.total_latency_ms.load(.monotonic);
        return .{
            .total_requests = total_requests,
            .total_embeddings = self.total_embeddings.load(.monotonic),
            .total_tokens = self.total_tokens.load(.monotonic),
            .total_errors = self.total_errors.load(.monotonic),
            .avg_latency_ms = if (total_requests > 0) @divFloor(total_latency, total_requests) else 0,
        };
    }
};

pub const AICoreStats = struct {
    total_requests: u64,
    total_embeddings: u64,
    total_tokens: u64,
    total_errors: u64,
    avg_latency_ms: u64,
};

// ============================================================================
// Stream Embedding Pipeline
// ============================================================================

pub const EmbeddingPipeline = struct {
    allocator: std.mem.Allocator,
    ai_core: *AICoreClient,
    model: EmbeddingModel,
    input_topic: []const u8,
    output_topic: []const u8,

    // Batching
    batch_buffer: std.ArrayList(BatchItem),
    batch_timeout_ms: u32,
    last_flush: i64,
    lock: std.Thread.Mutex,

    // Processing stats
    messages_processed: std.atomic.Value(u64),
    batches_processed: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, ai_core: *AICoreClient, input: []const u8, output: []const u8, model: EmbeddingModel) EmbeddingPipeline {
        return .{
            .allocator = allocator,
            .ai_core = ai_core,
            .model = model,
            .input_topic = input,
            .output_topic = output,
            .batch_buffer = std.ArrayList(BatchItem).init(allocator),
            .batch_timeout_ms = 100,
            .last_flush = std.time.milliTimestamp(),
            .lock = .{},
            .messages_processed = std.atomic.Value(u64).init(0),
            .batches_processed = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *EmbeddingPipeline) void {
        self.batch_buffer.deinit();
    }

    /// Add message to batch
    pub fn addMessage(self: *EmbeddingPipeline, message_id: i64, text: []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();

        try self.batch_buffer.append(.{
            .message_id = message_id,
            .text = text,
            .embedding = null,
        });

        // Check if batch is full or timeout reached
        if (self.batch_buffer.items.len >= self.ai_core.config.batch_size) {
            try self.flushBatchLocked();
        }
    }

    /// Check and flush if timeout reached
    pub fn checkFlush(self: *EmbeddingPipeline) !void {
        self.lock.lock();
        defer self.lock.unlock();

        const now = std.time.milliTimestamp();
        if (now - self.last_flush >= self.batch_timeout_ms and self.batch_buffer.items.len > 0) {
            try self.flushBatchLocked();
        }
    }

    fn flushBatchLocked(self: *EmbeddingPipeline) !void {
        if (self.batch_buffer.items.len == 0) return;

        log.info("Flushing embedding batch of {} items", .{self.batch_buffer.items.len});

        // Extract texts
        var texts = try self.allocator.alloc([]const u8, self.batch_buffer.items.len);
        defer self.allocator.free(texts);

        for (self.batch_buffer.items, 0..) |item, i| {
            texts[i] = item.text;
        }

        // Generate embeddings
        const response = try self.ai_core.embed(.{
            .texts = texts,
            .model = self.model,
        });

        // Store embeddings back
        for (response.embeddings) |emb| {
            if (emb.index < self.batch_buffer.items.len) {
                self.batch_buffer.items[emb.index].embedding = emb.vector;
            }
        }

        // In production: publish embeddings to output topic
        _ = self.messages_processed.fetchAdd(@intCast(self.batch_buffer.items.len), .monotonic);
        _ = self.batches_processed.fetchAdd(1, .monotonic);

        self.batch_buffer.clearRetainingCapacity();
        self.last_flush = std.time.milliTimestamp();
    }

    /// Force flush current batch
    pub fn flush(self: *EmbeddingPipeline) !void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.flushBatchLocked();
    }
};

pub const BatchItem = struct {
    message_id: i64,
    text: []const u8,
    embedding: ?[]f32,
};

// ============================================================================
// Vector Search Integration
// ============================================================================

pub const VectorSearchConfig = struct {
    /// HANA Vector Engine table
    table_name: []const u8 = "AIPROMPT_VECTORS",
    /// Schema
    schema: []const u8 = "AIPROMPT_STORAGE",
    /// Index type
    index_type: VectorIndexType = .hnsw,
    /// Distance metric
    distance_metric: DistanceMetric = .cosine,
    /// HNSW parameters
    hnsw_m: u32 = 16,
    hnsw_ef_construction: u32 = 200,
    hnsw_ef_search: u32 = 100,
};

pub const VectorIndexType = enum {
    flat,
    hnsw,
    ivf,
};

pub const DistanceMetric = enum {
    cosine,
    euclidean,
    dot_product,
};

// ============================================================================
// Tests
// ============================================================================

test "EmbeddingModel dimensions" {
    try std.testing.expectEqual(@as(u32, 1536), EmbeddingModel.TextEmbeddingAda002.getDimension());
    try std.testing.expectEqual(@as(u32, 384), EmbeddingModel.E5Small.getDimension());
    try std.testing.expectEqual(@as(u32, 1024), EmbeddingModel.E5Large.getDimension());
}

test "EmbeddingModel from string" {
    try std.testing.expectEqual(EmbeddingModel.TextEmbeddingAda002, EmbeddingModel.fromString("text-embedding-ada-002"));
    try std.testing.expectEqual(EmbeddingModel.E5Small, EmbeddingModel.fromString("e5-small"));
    try std.testing.expectEqual(EmbeddingModel.Custom, EmbeddingModel.fromString("unknown-model"));
}
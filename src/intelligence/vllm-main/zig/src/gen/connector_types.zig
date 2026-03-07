// ============================================================================
// Generated Zig Types from SDK Mangle Connectors
// ============================================================================
// Auto-generated from:
//   - mangle/connectors/llm.mg
//   - mangle/connectors/object_store.mg
//   - mangle/connectors/hana_vector.mg
//   - mangle/connectors/integration.mg
//
// DO NOT EDIT MANUALLY - regenerate with: zig build codegen

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// LLM Gateway Types (from llm.mg)
// ============================================================================

pub const LlmGatewayConfig = struct {
    service_id: []const u8,
    endpoint: []const u8,
    default_model: []const u8,
    credential_ref: []const u8,
    timeout_ms: i64,
    max_retries: i32,
};

pub const LlmModel = struct {
    model_id: []const u8,
    provider: []const u8,
    context_window: i32,
    input_cost_per_1k: f64,
    output_cost_per_1k: f64,
    supports_streaming: bool,
    supports_tools: bool,
    supports_vision: bool,
};

pub const LlmMessage = struct {
    role: Role,
    content: []const u8,
    name: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,

    pub const Role = enum {
        system,
        user,
        assistant,
        tool,
    };
};

pub const ToolCall = struct {
    id: []const u8,
    @"type": []const u8,
    function: FunctionCall,

    pub const FunctionCall = struct {
        name: []const u8,
        arguments: []const u8, // JSON string
    };
};

pub const LlmRequest = struct {
    request_id: []const u8,
    service_id: []const u8,
    model: []const u8,
    messages: []const LlmMessage,
    system_prompt: ?[]const u8 = null,
    max_tokens: i32 = 1024,
    temperature: f64 = 0.7,
    stream: bool = false,
    requested_at: i64,
};

pub const LlmResponse = struct {
    request_id: []const u8,
    model: []const u8,
    content: []const u8,
    finish_reason: FinishReason,
    input_tokens: i32,
    output_tokens: i32,
    duration_ms: i64,
    status: Status,

    pub const FinishReason = enum {
        stop,
        length,
        tool_calls,
        content_filter,
    };

    pub const Status = enum {
        success,
        @"error",
        timeout,
    };
};

pub const LlmStreamChunk = struct {
    request_id: []const u8,
    chunk_index: i32,
    content: []const u8,
    is_final: bool,
    finish_reason: ?LlmResponse.FinishReason = null,
};

pub const LlmEmbeddingRequest = struct {
    request_id: []const u8,
    service_id: []const u8,
    model: []const u8,
    input_text: []const u8,
    requested_at: i64,
};

pub const LlmEmbeddingResult = struct {
    request_id: []const u8,
    embedding_ref: []const u8, // TOON pointer
    dimensions: i32,
    duration_ms: i64,
};

// ============================================================================
// Object Store Types (from object_store.mg)
// ============================================================================

pub const ObjectStoreConfig = struct {
    service_id: []const u8,
    endpoint: []const u8,
    region: []const u8,
    bucket: []const u8,
    credential_ref: []const u8,
};

pub const ObjectMetadata = struct {
    object_id: []const u8,
    bucket: []const u8,
    key: []const u8,
    size_bytes: i64,
    content_type: []const u8,
    etag: []const u8,
    last_modified: i64,
};

pub const ObjectPutRequest = struct {
    request_id: []const u8,
    service_id: []const u8,
    bucket: []const u8,
    key: []const u8,
    content_ref: []const u8, // TOON pointer to data
    content_type: []const u8,
    requested_at: i64,
};

pub const ObjectGetRequest = struct {
    request_id: []const u8,
    service_id: []const u8,
    bucket: []const u8,
    key: []const u8,
    requested_at: i64,
};

pub const ObjectGetResult = struct {
    request_id: []const u8,
    content_ref: []const u8, // TOON pointer to data
    size_bytes: i64,
    content_type: []const u8,
    duration_ms: i64,
    status: Status,

    pub const Status = enum {
        success,
        not_found,
        @"error",
    };
};

pub const ObjectDeleteRequest = struct {
    request_id: []const u8,
    service_id: []const u8,
    bucket: []const u8,
    key: []const u8,
    requested_at: i64,
};

pub const ObjectOperationResult = struct {
    request_id: []const u8,
    operation: Operation,
    status: Status,
    duration_ms: i64,
    error_message: ?[]const u8 = null,

    pub const Operation = enum {
        put,
        get,
        delete,
        list,
    };

    pub const Status = enum {
        success,
        @"error",
    };
};

// ============================================================================
// HANA Vector Types (from hana_vector.mg)
// ============================================================================

pub const HanaConfig = struct {
    service_id: []const u8,
    host: []const u8,
    port: i32,
    schema: []const u8,
    credential_ref: []const u8,
};

pub const HanaConnection = struct {
    connection_id: []const u8,
    service_id: []const u8,
    status: Status,
    created_at: i64,
    last_used_at: i64,

    pub const Status = enum {
        connected,
        disconnected,
        @"error",
    };
};

pub const HanaVectorIndex = struct {
    index_id: []const u8,
    schema: []const u8,
    table: []const u8,
    column: []const u8,
    dimensions: i32,
    distance_metric: DistanceMetric,

    pub const DistanceMetric = enum {
        cosine,
        euclidean,
        dot_product,
    };
};

pub const HanaVectorInsert = struct {
    request_id: []const u8,
    service_id: []const u8,
    schema: []const u8,
    table: []const u8,
    record_id: []const u8,
    vector_data: []const u8, // TOON pointer or JSON array
    metadata: []const u8, // JSON
    requested_at: i64,
};

pub const HanaVectorSearch = struct {
    search_id: []const u8,
    index_id: []const u8,
    query_vector_ref: []const u8, // TOON pointer
    k: i32,
    filter: ?[]const u8 = null, // SQL WHERE clause
    executed_at: i64,
};

pub const HanaVectorResult = struct {
    search_id: []const u8,
    results: []const u8, // JSON array of {id, distance, metadata}
    duration_ms: i64,
};

pub const HanaVectorOperationResult = struct {
    request_id: []const u8,
    operation: Operation,
    status: Status,
    affected_rows: i32,
    duration_ms: i64,
    error_message: ?[]const u8 = null,

    pub const Operation = enum {
        create_index,
        insert,
        batch_insert,
        search,
        get,
        update,
        delete,
        drop_index,
    };

    pub const Status = enum {
        success,
        @"error",
    };
};

// ============================================================================
// RAG Types (from hana_vector.mg)
// ============================================================================

pub const RagDocument = struct {
    doc_id: []const u8,
    source: []const u8,
    doc_type: DocType,
    chunk_count: i32,
    total_tokens: i32,
    indexed_at: i64,

    pub const DocType = enum {
        pdf,
        txt,
        md,
        html,
    };
};

pub const RagChunk = struct {
    chunk_id: []const u8,
    doc_id: []const u8,
    chunk_index: i32,
    text: []const u8,
    token_count: i32,
    vector_ref: []const u8,
};

pub const RagQuery = struct {
    query_id: []const u8,
    user_query: []const u8,
    query_embedding_ref: []const u8,
    index_id: []const u8,
    k: i32,
    threshold: f64,
    requested_at: i64,
};

pub const RagResult = struct {
    query_id: []const u8,
    retrieved_chunks: []const u8, // JSON array
    context_text: []const u8,
    total_tokens: i32,
    retrieval_ms: i64,
};

// ============================================================================
// Service Integration Types (from integration.mg)
// ============================================================================

pub const PrivateLlmConfig = struct {
    service_id: []const u8,
    service_name: []const u8,
    version: []const u8,
    default_model: []const u8,
    max_context_tokens: i32,
    max_batch_size: i32,
    rag_enabled: bool,
};

pub const RagChatRequest = struct {
    request_id: []const u8,
    service_id: []const u8,
    user_query: []const u8,
    model: []const u8,
    rag_index_id: []const u8,
};

// ============================================================================
// Serialization Helpers
// ============================================================================

pub fn serializeJson(comptime T: type, value: T, allocator: Allocator) ![]u8 {
    return std.json.stringifyAlloc(allocator, value, .{});
}

pub fn deserializeJson(comptime T: type, json: []const u8, allocator: Allocator) !T {
    return std.json.parseFromSlice(T, allocator, json, .{});
}

// ============================================================================
// TOON Pointer Helpers
// ============================================================================

pub const ToonPointer = struct {
    prefix: []const u8,
    hash: []const u8,
    size: u64,

    pub fn format(self: ToonPointer, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "toon://{s}/{s}?size={d}", .{
            self.prefix,
            self.hash,
            self.size,
        });
    }

    pub fn parse(uri: []const u8) !ToonPointer {
        // Parse toon://prefix/hash?size=N format
        if (!std.mem.startsWith(u8, uri, "toon://")) {
            return error.InvalidToonUri;
        }
        const rest = uri[7..];
        const slash_idx = std.mem.indexOf(u8, rest, "/") orelse return error.InvalidToonUri;
        const prefix = rest[0..slash_idx];
        const after_slash = rest[slash_idx + 1 ..];
        const query_idx = std.mem.indexOf(u8, after_slash, "?") orelse return error.InvalidToonUri;
        const hash = after_slash[0..query_idx];
        // Parse size from query string
        const size_str = after_slash[query_idx + 6 ..]; // Skip "?size="
        const size = try std.fmt.parseInt(u64, size_str, 10);
        return ToonPointer{
            .prefix = prefix,
            .hash = hash,
            .size = size,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ToonPointer parse and format" {
    const allocator = std.testing.allocator;
    const ptr = ToonPointer{
        .prefix = "embeddings",
        .hash = "abc123",
        .size = 1024,
    };
    const formatted = try ptr.format(allocator);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("toon://embeddings/abc123?size=1024", formatted);

    const parsed = try ToonPointer.parse("toon://embeddings/xyz789?size=2048");
    try std.testing.expectEqualStrings("embeddings", parsed.prefix);
    try std.testing.expectEqualStrings("xyz789", parsed.hash);
    try std.testing.expectEqual(@as(u64, 2048), parsed.size);
}

test "LlmRequest serialization" {
    const allocator = std.testing.allocator;
    const req = LlmRequest{
        .request_id = "req-001",
        .service_id = "ai-core-privatellm",
        .model = "phi-2",
        .messages = &[_]LlmMessage{
            .{ .role = .user, .content = "Hello" },
        },
        .max_tokens = 100,
        .temperature = 0.7,
        .stream = false,
        .requested_at = 1708234567000,
    };
    const json = try serializeJson(LlmRequest, req, allocator);
    defer allocator.free(json);
    try std.testing.expect(json.len > 0);
}
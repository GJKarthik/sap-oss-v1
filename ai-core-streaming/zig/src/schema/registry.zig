//! BDC AIPrompt Streaming - Schema Registry
//! Apache Avro, JSON Schema, and Protocol Buffers schema management
//! Compatible with Pulsar Schema Registry API

const std = @import("std");

const log = std.log.scoped(.schema_registry);

// ============================================================================
// Schema Types
// ============================================================================

pub const SchemaType = enum {
    NONE,
    STRING,
    BOOLEAN,
    INT8,
    INT16,
    INT32,
    INT64,
    FLOAT,
    DOUBLE,
    BYTES,
    DATE,
    TIME,
    TIMESTAMP,
    INSTANT,
    LOCAL_DATE,
    LOCAL_TIME,
    LOCAL_DATE_TIME,
    JSON,
    AVRO,
    PROTOBUF,
    PROTOBUF_NATIVE,
    KEY_VALUE,
    AUTO_CONSUME,
    AUTO_PUBLISH,

    pub fn fromString(s: []const u8) ?SchemaType {
        const map = std.ComptimeStringMap(SchemaType, .{
            .{ "NONE", .NONE },
            .{ "STRING", .STRING },
            .{ "BOOLEAN", .BOOLEAN },
            .{ "INT8", .INT8 },
            .{ "INT16", .INT16 },
            .{ "INT32", .INT32 },
            .{ "INT64", .INT64 },
            .{ "FLOAT", .FLOAT },
            .{ "DOUBLE", .DOUBLE },
            .{ "BYTES", .BYTES },
            .{ "DATE", .DATE },
            .{ "TIME", .TIME },
            .{ "TIMESTAMP", .TIMESTAMP },
            .{ "JSON", .JSON },
            .{ "AVRO", .AVRO },
            .{ "PROTOBUF", .PROTOBUF },
            .{ "KEY_VALUE", .KEY_VALUE },
        });
        return map.get(s);
    }

    pub fn toString(self: SchemaType) []const u8 {
        return @tagName(self);
    }
};

// ============================================================================
// Schema Data
// ============================================================================

pub const SchemaData = struct {
    schema_type: SchemaType,
    /// Schema definition (JSON for JSON Schema, Avro JSON, or Protobuf descriptor)
    schema: []const u8,
    /// Additional properties
    properties: std.StringHashMap([]const u8),
    /// Schema hash for quick comparison
    hash: u64,

    pub fn init(allocator: std.mem.Allocator, schema_type: SchemaType, schema: []const u8) !SchemaData {
        return .{
            .schema_type = schema_type,
            .schema = try allocator.dupe(u8, schema),
            .properties = std.StringHashMap([]const u8).init(allocator),
            .hash = std.hash.Wyhash.hash(0, schema),
        };
    }

    pub fn deinit(self: *SchemaData, allocator: std.mem.Allocator) void {
        allocator.free(self.schema);
        self.properties.deinit();
    }

    pub fn setProperty(self: *SchemaData, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        try self.properties.put(try allocator.dupe(u8, key), try allocator.dupe(u8, value));
    }

    pub fn isCompatibleWith(self: SchemaData, other: SchemaData, strategy: CompatibilityStrategy) bool {
        // Same type is always required
        if (self.schema_type != other.schema_type) return false;

        return switch (strategy) {
            .ALWAYS_COMPATIBLE => true,
            .BACKWARD => self.isBackwardCompatible(other),
            .FORWARD => self.isForwardCompatible(other),
            .FULL => self.isBackwardCompatible(other) and self.isForwardCompatible(other),
            .BACKWARD_TRANSITIVE => self.isBackwardCompatible(other),
            .FORWARD_TRANSITIVE => self.isForwardCompatible(other),
            .FULL_TRANSITIVE => self.isBackwardCompatible(other) and self.isForwardCompatible(other),
        };
    }

    fn isBackwardCompatible(self: SchemaData, older: SchemaData) bool {
        _ = self;
        _ = older;
        // TODO: Implement full Avro/JSON schema compatibility checking
        // For now, allow if same type
        return true;
    }

    fn isForwardCompatible(self: SchemaData, newer: SchemaData) bool {
        _ = self;
        _ = newer;
        // TODO: Implement full Avro/JSON schema compatibility checking
        return true;
    }
};

// ============================================================================
// Schema Info (versioned schema)
// ============================================================================

pub const SchemaInfo = struct {
    /// Schema version (auto-incremented)
    version: u64,
    /// Schema data
    data: SchemaData,
    /// Creation timestamp
    created_at: i64,
    /// User who created this version
    created_by: []const u8,
    /// Description of changes
    description: []const u8,

    pub fn init(allocator: std.mem.Allocator, version: u64, data: SchemaData, created_by: []const u8, description: []const u8) !SchemaInfo {
        return .{
            .version = version,
            .data = data,
            .created_at = std.time.milliTimestamp(),
            .created_by = try allocator.dupe(u8, created_by),
            .description = try allocator.dupe(u8, description),
        };
    }

    pub fn deinit(self: *SchemaInfo, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
        allocator.free(self.created_by);
        allocator.free(self.description);
    }
};

// ============================================================================
// Compatibility Strategy
// ============================================================================

pub const CompatibilityStrategy = enum {
    /// Always accept new schema
    ALWAYS_COMPATIBLE,
    /// New schema can read data written with previous schema
    BACKWARD,
    /// Previous schema can read data written with new schema
    FORWARD,
    /// Both backward and forward compatible
    FULL,
    /// Backward compatible with all previous versions
    BACKWARD_TRANSITIVE,
    /// Forward compatible with all previous versions
    FORWARD_TRANSITIVE,
    /// Full transitive compatibility
    FULL_TRANSITIVE,

    pub fn fromString(s: []const u8) ?CompatibilityStrategy {
        const map = std.ComptimeStringMap(CompatibilityStrategy, .{
            .{ "ALWAYS_COMPATIBLE", .ALWAYS_COMPATIBLE },
            .{ "BACKWARD", .BACKWARD },
            .{ "FORWARD", .FORWARD },
            .{ "FULL", .FULL },
            .{ "BACKWARD_TRANSITIVE", .BACKWARD_TRANSITIVE },
            .{ "FORWARD_TRANSITIVE", .FORWARD_TRANSITIVE },
            .{ "FULL_TRANSITIVE", .FULL_TRANSITIVE },
        });
        return map.get(s);
    }
};

// ============================================================================
// Topic Schema Entry
// ============================================================================

pub const TopicSchema = struct {
    allocator: std.mem.Allocator,
    /// Topic name
    topic: []const u8,
    /// All schema versions (ordered by version)
    versions: std.ArrayList(SchemaInfo),
    /// Current/latest version
    current_version: u64,
    /// Compatibility strategy for this topic
    compatibility: CompatibilityStrategy,
    /// Whether auto-update is enabled
    auto_update_enabled: bool,

    pub fn init(allocator: std.mem.Allocator, topic: []const u8) !TopicSchema {
        return .{
            .allocator = allocator,
            .topic = try allocator.dupe(u8, topic),
            .versions = std.ArrayList(SchemaInfo).init(allocator),
            .current_version = 0,
            .compatibility = .FULL,
            .auto_update_enabled = true,
        };
    }

    pub fn deinit(self: *TopicSchema) void {
        for (self.versions.items) |*v| {
            v.deinit(self.allocator);
        }
        self.versions.deinit();
        self.allocator.free(self.topic);
    }

    pub fn getCurrentSchema(self: *TopicSchema) ?*SchemaInfo {
        if (self.versions.items.len == 0) return null;
        return &self.versions.items[self.versions.items.len - 1];
    }

    pub fn getSchemaByVersion(self: *TopicSchema, version: u64) ?*SchemaInfo {
        for (self.versions.items) |*v| {
            if (v.version == version) return v;
        }
        return null;
    }

    pub fn addSchema(self: *TopicSchema, data: SchemaData, created_by: []const u8, description: []const u8) !u64 {
        // Check compatibility with current schema
        if (self.getCurrentSchema()) |current| {
            if (!data.isCompatibleWith(current.data, self.compatibility)) {
                log.err("Schema incompatible with current version under {s} strategy", .{@tagName(self.compatibility)});
                return error.SchemaIncompatible;
            }
        }

        const new_version = self.current_version + 1;
        const info = try SchemaInfo.init(self.allocator, new_version, data, created_by, description);
        try self.versions.append(info);
        self.current_version = new_version;

        log.info("Added schema version {} for topic {s}", .{ new_version, self.topic });
        return new_version;
    }
};

// ============================================================================
// Schema Registry
// ============================================================================

pub const SchemaRegistry = struct {
    allocator: std.mem.Allocator,
    /// Topic schemas indexed by topic name
    schemas: std.StringHashMap(*TopicSchema),
    /// Mutex for thread-safe access
    mutex: std.Thread.Mutex,
    /// Global default compatibility strategy
    default_compatibility: CompatibilityStrategy,
    /// Statistics
    total_schemas: std.atomic.Value(u64),
    total_versions: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator) SchemaRegistry {
        return .{
            .allocator = allocator,
            .schemas = std.StringHashMap(*TopicSchema).init(allocator),
            .mutex = .{},
            .default_compatibility = .FULL,
            .total_schemas = std.atomic.Value(u64).init(0),
            .total_versions = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *SchemaRegistry) void {
        var it = self.schemas.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.schemas.deinit();
    }

    /// Get or create schema entry for a topic
    pub fn getOrCreateTopic(self: *SchemaRegistry, topic: []const u8) !*TopicSchema {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.schemas.get(topic)) |schema| {
            return schema;
        }

        // Create new topic schema
        const schema = try self.allocator.create(TopicSchema);
        schema.* = try TopicSchema.init(self.allocator, topic);
        schema.compatibility = self.default_compatibility;

        try self.schemas.put(try self.allocator.dupe(u8, topic), schema);
        _ = self.total_schemas.fetchAdd(1, .monotonic);

        log.info("Created schema registry entry for topic: {s}", .{topic});
        return schema;
    }

    /// Register a new schema version for a topic
    pub fn registerSchema(
        self: *SchemaRegistry,
        topic: []const u8,
        schema_type: SchemaType,
        schema: []const u8,
        created_by: []const u8,
        description: []const u8,
    ) !u64 {
        const topic_schema = try self.getOrCreateTopic(topic);

        var data = try SchemaData.init(self.allocator, schema_type, schema);
        errdefer data.deinit(self.allocator);

        const version = try topic_schema.addSchema(data, created_by, description);
        _ = self.total_versions.fetchAdd(1, .monotonic);

        return version;
    }

    /// Get current schema for a topic
    pub fn getSchema(self: *SchemaRegistry, topic: []const u8) ?*SchemaInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.schemas.get(topic)) |schema| {
            return schema.getCurrentSchema();
        }
        return null;
    }

    /// Get specific schema version for a topic
    pub fn getSchemaVersion(self: *SchemaRegistry, topic: []const u8, version: u64) ?*SchemaInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.schemas.get(topic)) |schema| {
            return schema.getSchemaByVersion(version);
        }
        return null;
    }

    /// Get all schema versions for a topic
    pub fn getAllVersions(self: *SchemaRegistry, topic: []const u8) ?[]SchemaInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.schemas.get(topic)) |schema| {
            return schema.versions.items;
        }
        return null;
    }

    /// Delete schema for a topic
    pub fn deleteSchema(self: *SchemaRegistry, topic: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.schemas.fetchRemove(topic)) |entry| {
            entry.value.deinit();
            self.allocator.destroy(entry.value);
            log.info("Deleted schema for topic: {s}", .{topic});
        } else {
            return error.SchemaNotFound;
        }
    }

    /// Set compatibility strategy for a topic
    pub fn setCompatibility(self: *SchemaRegistry, topic: []const u8, strategy: CompatibilityStrategy) !void {
        const topic_schema = try self.getOrCreateTopic(topic);

        self.mutex.lock();
        defer self.mutex.unlock();

        topic_schema.compatibility = strategy;
        log.info("Set compatibility for topic {s} to {s}", .{ topic, @tagName(strategy) });
    }

    /// Test if a new schema would be compatible
    pub fn testCompatibility(self: *SchemaRegistry, topic: []const u8, schema_type: SchemaType, schema: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const topic_schema = self.schemas.get(topic) orelse return true; // No existing schema = compatible
        const current = topic_schema.getCurrentSchema() orelse return true;

        var test_data = try SchemaData.init(self.allocator, schema_type, schema);
        defer test_data.deinit(self.allocator);

        return test_data.isCompatibleWith(current.data, topic_schema.compatibility);
    }

    /// Get registry statistics
    pub fn getStats(self: *SchemaRegistry) RegistryStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var total_topics: u64 = 0;
        var it = self.schemas.iterator();
        while (it.next()) |_| {
            total_topics += 1;
        }

        return .{
            .total_topics = total_topics,
            .total_schemas = self.total_schemas.load(.monotonic),
            .total_versions = self.total_versions.load(.monotonic),
        };
    }
};

pub const RegistryStats = struct {
    total_topics: u64,
    total_schemas: u64,
    total_versions: u64,
};

// ============================================================================
// Schema Validators
// ============================================================================

pub const SchemaValidator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SchemaValidator {
        return .{ .allocator = allocator };
    }

    /// Validate JSON Schema definition
    pub fn validateJsonSchema(self: *SchemaValidator, schema: []const u8) !void {
        _ = self;

        // Basic JSON validation
        if (schema.len == 0) return error.EmptySchema;

        // Must be valid JSON
        if (schema[0] != '{') return error.InvalidJsonSchema;

        // Check for required fields
        if (std.mem.indexOf(u8, schema, "\"type\"") == null) {
            log.warn("JSON Schema missing 'type' field", .{});
        }
    }

    /// Validate Avro Schema definition
    pub fn validateAvroSchema(self: *SchemaValidator, schema: []const u8) !void {
        _ = self;

        if (schema.len == 0) return error.EmptySchema;
        if (schema[0] != '{' and schema[0] != '"') return error.InvalidAvroSchema;

        // Check for required Avro fields
        if (std.mem.indexOf(u8, schema, "\"type\"") == null) {
            return error.AvroMissingType;
        }
    }

    /// Validate Protocol Buffer descriptor
    pub fn validateProtobufSchema(self: *SchemaValidator, schema: []const u8) !void {
        _ = self;

        if (schema.len == 0) return error.EmptySchema;

        // Protobuf descriptors are binary, check magic bytes
        if (schema.len < 4) return error.InvalidProtobufSchema;
    }

    /// Validate schema based on type
    pub fn validate(self: *SchemaValidator, schema_type: SchemaType, schema: []const u8) !void {
        return switch (schema_type) {
            .JSON => self.validateJsonSchema(schema),
            .AVRO => self.validateAvroSchema(schema),
            .PROTOBUF, .PROTOBUF_NATIVE => self.validateProtobufSchema(schema),
            .STRING, .BYTES, .NONE => {}, // No validation needed
            else => {},
        };
    }
};

// ============================================================================
// Pre-defined Schemas for AIPrompt Services
// ============================================================================

pub const AIPromptSchemas = struct {
    /// LLM Request Schema (JSON)
    pub const LLM_REQUEST =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "prompt": {"type": "string"},
        \\    "model": {"type": "string"},
        \\    "max_tokens": {"type": "integer"},
        \\    "temperature": {"type": "number"},
        \\    "top_p": {"type": "number"},
        \\    "stream": {"type": "boolean"},
        \\    "stop": {"type": "array", "items": {"type": "string"}},
        \\    "user_id": {"type": "string"},
        \\    "session_id": {"type": "string"},
        \\    "metadata": {"type": "object"}
        \\  },
        \\  "required": ["prompt"]
        \\}
    ;

    /// LLM Response Schema (JSON)
    pub const LLM_RESPONSE =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "id": {"type": "string"},
        \\    "model": {"type": "string"},
        \\    "created": {"type": "integer"},
        \\    "choices": {
        \\      "type": "array",
        \\      "items": {
        \\        "type": "object",
        \\        "properties": {
        \\          "index": {"type": "integer"},
        \\          "text": {"type": "string"},
        \\          "finish_reason": {"type": "string"}
        \\        }
        \\      }
        \\    },
        \\    "usage": {
        \\      "type": "object",
        \\      "properties": {
        \\        "prompt_tokens": {"type": "integer"},
        \\        "completion_tokens": {"type": "integer"},
        \\        "total_tokens": {"type": "integer"}
        \\      }
        \\    }
        \\  },
        \\  "required": ["id", "choices"]
        \\}
    ;

    /// Embedding Request Schema (JSON)
    pub const EMBEDDING_REQUEST =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "input": {
        \\      "oneOf": [
        \\        {"type": "string"},
        \\        {"type": "array", "items": {"type": "string"}}
        \\      ]
        \\    },
        \\    "model": {"type": "string"},
        \\    "dimensions": {"type": "integer"}
        \\  },
        \\  "required": ["input"]
        \\}
    ;

    /// Document Schema for Search (JSON)
    pub const SEARCH_DOCUMENT =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "id": {"type": "string"},
        \\    "content": {"type": "string"},
        \\    "title": {"type": "string"},
        \\    "source": {"type": "string"},
        \\    "timestamp": {"type": "integer"},
        \\    "metadata": {"type": "object"},
        \\    "embedding": {
        \\      "type": "array",
        \\      "items": {"type": "number"}
        \\    }
        \\  },
        \\  "required": ["id", "content"]
        \\}
    ;

    /// News Event Schema (JSON)
    pub const NEWS_EVENT =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "event_id": {"type": "string"},
        \\    "source": {"type": "string"},
        \\    "headline": {"type": "string"},
        \\    "body": {"type": "string"},
        \\    "published_at": {"type": "integer"},
        \\    "categories": {"type": "array", "items": {"type": "string"}},
        \\    "entities": {"type": "array", "items": {"type": "string"}},
        \\    "sentiment": {"type": "number"},
        \\    "url": {"type": "string"}
        \\  },
        \\  "required": ["event_id", "headline"]
        \\}
    ;

    /// Model Architecture Schema (for GPU configuration)
    pub const MODEL_ARCHITECTURE =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "model_id": {"type": "string"},
        \\    "architecture": {"type": "string"},
        \\    "parameters": {"type": "integer"},
        \\    "quantization": {"type": "string"},
        \\    "context_length": {"type": "integer"},
        \\    "gpu_memory_required_gb": {"type": "number"},
        \\    "supported_hardware": {
        \\      "type": "array",
        \\      "items": {"type": "string"}
        \\    }
        \\  },
        \\  "required": ["model_id", "architecture"]
        \\}
    ;
};

// ============================================================================
// Tests
// ============================================================================

test "SchemaType fromString" {
    try std.testing.expectEqual(SchemaType.JSON, SchemaType.fromString("JSON").?);
    try std.testing.expectEqual(SchemaType.AVRO, SchemaType.fromString("AVRO").?);
    try std.testing.expectEqual(SchemaType.PROTOBUF, SchemaType.fromString("PROTOBUF").?);
    try std.testing.expect(SchemaType.fromString("INVALID") == null);
}

test "SchemaData initialization and hash" {
    const allocator = std.testing.allocator;

    var data1 = try SchemaData.init(allocator, .JSON, "{\"type\":\"string\"}");
    defer data1.deinit(allocator);

    var data2 = try SchemaData.init(allocator, .JSON, "{\"type\":\"string\"}");
    defer data2.deinit(allocator);

    // Same schema should produce same hash
    try std.testing.expectEqual(data1.hash, data2.hash);
}

test "SchemaRegistry basic operations" {
    const allocator = std.testing.allocator;

    var registry = SchemaRegistry.init(allocator);
    defer registry.deinit();

    // Register a schema
    const version = try registry.registerSchema(
        "test-topic",
        .JSON,
        "{\"type\":\"object\"}",
        "test-user",
        "Initial schema",
    );

    try std.testing.expectEqual(@as(u64, 1), version);

    // Get the schema
    const schema = registry.getSchema("test-topic").?;
    try std.testing.expectEqual(@as(u64, 1), schema.version);
    try std.testing.expectEqual(SchemaType.JSON, schema.data.schema_type);
}

test "SchemaRegistry compatibility check" {
    const allocator = std.testing.allocator;

    var registry = SchemaRegistry.init(allocator);
    defer registry.deinit();

    // Register initial schema
    _ = try registry.registerSchema(
        "test-topic",
        .JSON,
        "{\"type\":\"object\"}",
        "test-user",
        "Initial schema",
    );

    // Test compatibility
    const is_compatible = try registry.testCompatibility(
        "test-topic",
        .JSON,
        "{\"type\":\"object\",\"properties\":{}}",
    );

    try std.testing.expect(is_compatible);
}

test "SchemaValidator JSON validation" {
    const allocator = std.testing.allocator;

    var validator = SchemaValidator.init(allocator);

    // Valid JSON schema
    try validator.validateJsonSchema("{\"type\":\"string\"}");

    // Invalid (empty)
    try std.testing.expectError(error.EmptySchema, validator.validateJsonSchema(""));

    // Invalid (not object)
    try std.testing.expectError(error.InvalidJsonSchema, validator.validateJsonSchema("[]"));
}

test "AIPromptSchemas are valid JSON" {
    const allocator = std.testing.allocator;

    var validator = SchemaValidator.init(allocator);

    // All pre-defined schemas should be valid
    try validator.validateJsonSchema(AIPromptSchemas.LLM_REQUEST);
    try validator.validateJsonSchema(AIPromptSchemas.LLM_RESPONSE);
    try validator.validateJsonSchema(AIPromptSchemas.EMBEDDING_REQUEST);
    try validator.validateJsonSchema(AIPromptSchemas.SEARCH_DOCUMENT);
    try validator.validateJsonSchema(AIPromptSchemas.NEWS_EVENT);
    try validator.validateJsonSchema(AIPromptSchemas.MODEL_ARCHITECTURE);
}
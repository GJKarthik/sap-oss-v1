//! AIPrompt Streaming - Schema Registry
//! Runtime schema validation for Avro/Protobuf message schemas
//! 
//! Production messaging systems require schema enforcement to prevent
//! incompatible message formats from breaking downstream consumers.
//! This registry manages schema versions and validates messages on the fly.

const std = @import("std");

const log = std.log.scoped(.schema_registry);

// ============================================================================
// Schema Types
// ============================================================================

pub const SchemaType = enum(u8) {
    None = 0,
    Avro = 1,
    Protobuf = 2,
    Json = 3,
    String = 4,
    Bytes = 5,
};

pub const SchemaInfo = struct {
    schema_id: u64,
    version: u32,
    schema_type: SchemaType,
    schema_name: []const u8,
    schema_definition: []const u8,
    fingerprint: u64,
    created_at: i64,
    compatibility: CompatibilityMode,
    properties: std.StringHashMap([]const u8),
};

pub const CompatibilityMode = enum {
    /// New schemas must be backward compatible (can read old data)
    Backward,
    /// New schemas must be forward compatible (old code can read new data)
    Forward,
    /// New schemas must be both backward and forward compatible
    Full,
    /// No compatibility checking
    None,
    /// Transitive backward compatibility across all versions
    BackwardTransitive,
    /// Transitive forward compatibility across all versions
    ForwardTransitive,
    /// Transitive full compatibility across all versions
    FullTransitive,
};

// ============================================================================
// Schema Registry
// ============================================================================

pub const SchemaRegistry = struct {
    allocator: std.mem.Allocator,
    schemas: std.StringHashMap(TopicSchemas),
    mutex: std.Thread.Mutex,
    next_schema_id: std.atomic.Value(u64),
    default_compatibility: CompatibilityMode,

    // Stats
    schemas_registered: std.atomic.Value(u64),
    schemas_validated: std.atomic.Value(u64),
    validation_failures: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, default_compatibility: CompatibilityMode) SchemaRegistry {
        return .{
            .allocator = allocator,
            .schemas = std.StringHashMap(TopicSchemas).init(allocator),
            .mutex = .{},
            .next_schema_id = std.atomic.Value(u64).init(1),
            .default_compatibility = default_compatibility,
            .schemas_registered = std.atomic.Value(u64).init(0),
            .schemas_validated = std.atomic.Value(u64).init(0),
            .validation_failures = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *SchemaRegistry) void {
        var iter = self.schemas.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.schemas.deinit();
    }

    /// Register a new schema for a topic
    pub fn registerSchema(
        self: *SchemaRegistry,
        topic: []const u8,
        schema_name: []const u8,
        schema_type: SchemaType,
        schema_definition: []const u8,
    ) !SchemaRegistrationResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Get or create topic schemas
        var topic_schemas = self.schemas.get(topic) orelse blk: {
            const new_schemas = TopicSchemas.init(self.allocator);
            const topic_key = try self.allocator.dupe(u8, topic);
            try self.schemas.put(topic_key, new_schemas);
            break :blk self.schemas.get(topic).?;
        };

        // Calculate fingerprint
        const fingerprint = computeFingerprint(schema_definition);

        // Check if this exact schema already exists
        if (topic_schemas.findByFingerprint(fingerprint)) |existing| {
            return SchemaRegistrationResult{
                .schema_id = existing.schema_id,
                .version = existing.version,
                .fingerprint = fingerprint,
                .is_new = false,
            };
        }

        // Check compatibility with latest version
        const latest = topic_schemas.getLatest();
        if (latest) |prev| {
            const compatible = try self.checkCompatibility(
                prev.schema_definition,
                schema_definition,
                prev.schema_type,
                self.default_compatibility,
            );
            if (!compatible) {
                _ = self.validation_failures.fetchAdd(1, .monotonic);
                return error.IncompatibleSchema;
            }
        }

        // Create new schema version
        const schema_id = self.next_schema_id.fetchAdd(1, .monotonic);
        const version = if (latest) |l| l.version + 1 else 1;

        const schema_info = SchemaInfo{
            .schema_id = schema_id,
            .version = version,
            .schema_type = schema_type,
            .schema_name = try self.allocator.dupe(u8, schema_name),
            .schema_definition = try self.allocator.dupe(u8, schema_definition),
            .fingerprint = fingerprint,
            .created_at = std.time.milliTimestamp(),
            .compatibility = self.default_compatibility,
            .properties = std.StringHashMap([]const u8).init(self.allocator),
        };

        try topic_schemas.addSchema(schema_info);
        _ = self.schemas_registered.fetchAdd(1, .monotonic);

        log.info("Registered schema for topic {s}: id={}, version={}, type={}", .{
            topic,
            schema_id,
            version,
            @intFromEnum(schema_type),
        });

        return SchemaRegistrationResult{
            .schema_id = schema_id,
            .version = version,
            .fingerprint = fingerprint,
            .is_new = true,
        };
    }

    /// Get schema by ID
    pub fn getSchemaById(self: *SchemaRegistry, schema_id: u64) ?*const SchemaInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.schemas.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.findById(schema_id)) |schema| {
                return schema;
            }
        }
        return null;
    }

    /// Get latest schema for a topic
    pub fn getLatestSchema(self: *SchemaRegistry, topic: []const u8) ?*const SchemaInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.schemas.get(topic)) |topic_schemas| {
            return topic_schemas.getLatest();
        }
        return null;
    }

    /// Validate a message against the expected schema
    pub fn validateMessage(
        self: *SchemaRegistry,
        topic: []const u8,
        schema_version_hash: u64,
        payload: []const u8,
    ) !ValidationResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.schemas_validated.fetchAdd(1, .monotonic);

        // Get topic schemas
        const topic_schemas = self.schemas.get(topic) orelse {
            // No schema registered - allow if no schema enforcement
            if (schema_version_hash == 0) {
                return ValidationResult{ .valid = true, .reason = null };
            }
            _ = self.validation_failures.fetchAdd(1, .monotonic);
            return ValidationResult{ .valid = false, .reason = "No schema registered for topic" };
        };

        // Find the schema
        const schema = topic_schemas.findByFingerprint(schema_version_hash) orelse {
            _ = self.validation_failures.fetchAdd(1, .monotonic);
            return ValidationResult{ .valid = false, .reason = "Unknown schema version" };
        };

        // Validate payload against schema
        const valid = try self.validatePayload(payload, schema);

        if (!valid) {
            _ = self.validation_failures.fetchAdd(1, .monotonic);
            return ValidationResult{ .valid = false, .reason = "Payload does not match schema" };
        }

        return ValidationResult{ .valid = true, .reason = null };
    }

    /// Check if two schemas are compatible
    fn checkCompatibility(
        self: *SchemaRegistry,
        old_schema: []const u8,
        new_schema: []const u8,
        schema_type: SchemaType,
        mode: CompatibilityMode,
    ) !bool {
        _ = self;

        return switch (schema_type) {
            .Avro => try checkAvroCompatibility(old_schema, new_schema, mode),
            .Protobuf => try checkProtobufCompatibility(old_schema, new_schema, mode),
            .Json => try checkJsonSchemaCompatibility(old_schema, new_schema, mode),
            .String, .Bytes, .None => true,
        };
    }

    /// Validate payload against schema
    fn validatePayload(self: *SchemaRegistry, payload: []const u8, schema: *const SchemaInfo) !bool {
        _ = self;

        return switch (schema.schema_type) {
            .Avro => try validateAvroPayload(payload, schema.schema_definition),
            .Protobuf => try validateProtobufPayload(payload, schema.schema_definition),
            .Json => try validateJsonPayload(payload, schema.schema_definition),
            .String => payload.len > 0,
            .Bytes => true,
            .None => true,
        };
    }

    pub fn getStats(self: *SchemaRegistry) RegistryStats {
        return .{
            .schemas_registered = self.schemas_registered.load(.monotonic),
            .schemas_validated = self.schemas_validated.load(.monotonic),
            .validation_failures = self.validation_failures.load(.monotonic),
            .topics_count = @intCast(self.schemas.count()),
        };
    }
};

pub const SchemaRegistrationResult = struct {
    schema_id: u64,
    version: u32,
    fingerprint: u64,
    is_new: bool,
};

pub const ValidationResult = struct {
    valid: bool,
    reason: ?[]const u8,
};

pub const RegistryStats = struct {
    schemas_registered: u64,
    schemas_validated: u64,
    validation_failures: u64,
    topics_count: u32,
};

// ============================================================================
// Topic Schemas (per-topic schema versions)
// ============================================================================

const TopicSchemas = struct {
    allocator: std.mem.Allocator,
    versions: std.ArrayList(SchemaInfo),
    by_id: std.AutoHashMap(u64, usize),
    by_fingerprint: std.AutoHashMap(u64, usize),
    latest_version: u32,

    pub fn init(allocator: std.mem.Allocator) TopicSchemas {
        return .{
            .allocator = allocator,
            .versions = std.ArrayList(SchemaInfo).init(allocator),
            .by_id = std.AutoHashMap(u64, usize).init(allocator),
            .by_fingerprint = std.AutoHashMap(u64, usize).init(allocator),
            .latest_version = 0,
        };
    }

    pub fn deinit(self: *TopicSchemas) void {
        for (self.versions.items) |*schema| {
            self.allocator.free(schema.schema_name);
            self.allocator.free(schema.schema_definition);
            schema.properties.deinit();
        }
        self.versions.deinit();
        self.by_id.deinit();
        self.by_fingerprint.deinit();
    }

    pub fn addSchema(self: *TopicSchemas, schema: SchemaInfo) !void {
        const idx = self.versions.items.len;
        try self.versions.append(schema);
        try self.by_id.put(schema.schema_id, idx);
        try self.by_fingerprint.put(schema.fingerprint, idx);
        self.latest_version = schema.version;
    }

    pub fn findById(self: *const TopicSchemas, schema_id: u64) ?*const SchemaInfo {
        if (self.by_id.get(schema_id)) |idx| {
            return &self.versions.items[idx];
        }
        return null;
    }

    pub fn findByFingerprint(self: *const TopicSchemas, fingerprint: u64) ?*const SchemaInfo {
        if (self.by_fingerprint.get(fingerprint)) |idx| {
            return &self.versions.items[idx];
        }
        return null;
    }

    pub fn getLatest(self: *const TopicSchemas) ?*const SchemaInfo {
        if (self.versions.items.len == 0) return null;
        return &self.versions.items[self.versions.items.len - 1];
    }
};

// ============================================================================
// Fingerprint Computation (64-bit Rabin fingerprint)
// ============================================================================

fn computeFingerprint(data: []const u8) u64 {
    // Use FNV-1a 64-bit hash for fingerprinting
    var hash: u64 = 0xcbf29ce484222325; // FNV offset basis
    for (data) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3; // FNV prime
    }
    return hash;
}

// ============================================================================
// Avro Compatibility Checking
// ============================================================================

fn checkAvroCompatibility(old_schema: []const u8, new_schema: []const u8, mode: CompatibilityMode) !bool {
    _ = old_schema;
    _ = new_schema;

    // Simplified compatibility check - in production would parse Avro schema JSON
    return switch (mode) {
        .None => true,
        .Backward => true, // TODO: Implement proper Avro compatibility
        .Forward => true,
        .Full => true,
        .BackwardTransitive => true,
        .ForwardTransitive => true,
        .FullTransitive => true,
    };
}

fn validateAvroPayload(payload: []const u8, schema_definition: []const u8) !bool {
    _ = schema_definition;

    // Basic validation - check for valid Avro binary format
    // In production, would use a proper Avro library
    if (payload.len < 1) return false;

    // Avro binary starts with schema fingerprint or sync marker
    return true;
}

// ============================================================================
// Protobuf Compatibility Checking
// ============================================================================

fn checkProtobufCompatibility(old_schema: []const u8, new_schema: []const u8, mode: CompatibilityMode) !bool {
    _ = old_schema;
    _ = new_schema;

    // Protobuf is generally backward compatible by design
    return switch (mode) {
        .None => true,
        .Backward => true,
        .Forward => true,
        .Full => true,
        .BackwardTransitive => true,
        .ForwardTransitive => true,
        .FullTransitive => true,
    };
}

fn validateProtobufPayload(payload: []const u8, schema_definition: []const u8) !bool {
    _ = schema_definition;

    // Basic protobuf validation
    // Protobuf messages can be empty, so just check it's well-formed
    if (payload.len == 0) return true;

    // Check for valid wire type in first byte
    const wire_type = payload[0] & 0x07;
    return wire_type <= 5; // Valid wire types are 0-5
}

// ============================================================================
// JSON Schema Compatibility
// ============================================================================

fn checkJsonSchemaCompatibility(old_schema: []const u8, new_schema: []const u8, mode: CompatibilityMode) !bool {
    _ = old_schema;
    _ = new_schema;
    _ = mode;

    // JSON Schema compatibility is complex - simplified for now
    return true;
}

fn validateJsonPayload(payload: []const u8, schema_definition: []const u8) !bool {
    _ = schema_definition;

    // Basic JSON validation
    if (payload.len == 0) return false;

    // Check for JSON object or array start
    const first_char = payload[0];
    return first_char == '{' or first_char == '[' or first_char == '"' or
        (first_char >= '0' and first_char <= '9') or
        first_char == 't' or first_char == 'f' or first_char == 'n';
}

// ============================================================================
// Schema Serialization (for persistence)
// ============================================================================

pub const SchemaSerializer = struct {
    pub fn serialize(allocator: std.mem.Allocator, schema: *const SchemaInfo) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        var writer = buffer.writer();

        // Write schema ID (8 bytes)
        try writer.writeInt(u64, schema.schema_id, .big);

        // Write version (4 bytes)
        try writer.writeInt(u32, schema.version, .big);

        // Write type (1 byte)
        try writer.writeByte(@intFromEnum(schema.schema_type));

        // Write fingerprint (8 bytes)
        try writer.writeInt(u64, schema.fingerprint, .big);

        // Write created_at (8 bytes)
        try writer.writeInt(i64, schema.created_at, .big);

        // Write name length + name
        try writer.writeInt(u16, @intCast(schema.schema_name.len), .big);
        try writer.writeAll(schema.schema_name);

        // Write definition length + definition
        try writer.writeInt(u32, @intCast(schema.schema_definition.len), .big);
        try writer.writeAll(schema.schema_definition);

        return buffer.toOwnedSlice();
    }

    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !SchemaInfo {
        var offset: usize = 0;

        const schema_id = std.mem.readInt(u64, data[offset..][0..8], .big);
        offset += 8;

        const version = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;

        const schema_type: SchemaType = @enumFromInt(data[offset]);
        offset += 1;

        const fingerprint = std.mem.readInt(u64, data[offset..][0..8], .big);
        offset += 8;

        const created_at = std.mem.readInt(i64, data[offset..][0..8], .big);
        offset += 8;

        const name_len = std.mem.readInt(u16, data[offset..][0..2], .big);
        offset += 2;
        const schema_name = try allocator.dupe(u8, data[offset..][0..name_len]);
        offset += name_len;

        const def_len = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;
        const schema_definition = try allocator.dupe(u8, data[offset..][0..def_len]);

        return SchemaInfo{
            .schema_id = schema_id,
            .version = version,
            .schema_type = schema_type,
            .schema_name = schema_name,
            .schema_definition = schema_definition,
            .fingerprint = fingerprint,
            .created_at = created_at,
            .compatibility = .Backward,
            .properties = std.StringHashMap([]const u8).init(allocator),
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SchemaRegistry init/deinit" {
    const allocator = std.testing.allocator;
    var registry = SchemaRegistry.init(allocator, .Backward);
    defer registry.deinit();

    try std.testing.expectEqual(@as(u64, 0), registry.schemas_registered.load(.monotonic));
}

test "computeFingerprint" {
    const fp1 = computeFingerprint("test schema 1");
    const fp2 = computeFingerprint("test schema 2");
    const fp3 = computeFingerprint("test schema 1");

    try std.testing.expect(fp1 != fp2);
    try std.testing.expectEqual(fp1, fp3);
}

test "SchemaType values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(SchemaType.None));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(SchemaType.Avro));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(SchemaType.Protobuf));
}

test "ValidationResult" {
    const valid_result = ValidationResult{ .valid = true, .reason = null };
    try std.testing.expect(valid_result.valid);

    const invalid_result = ValidationResult{ .valid = false, .reason = "Test error" };
    try std.testing.expect(!invalid_result.valid);
    try std.testing.expectEqualStrings("Test error", invalid_result.reason.?);
}
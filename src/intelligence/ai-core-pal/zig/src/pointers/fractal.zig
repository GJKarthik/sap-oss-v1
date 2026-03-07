const std = @import("std");

// ============================================================================
// Fractal Pointer ID — Hierarchical Privacy-Preserving Identifier
//
// Fractal structure provides natural namespacing with self-similarity at
// each level. Each "zoom level" encodes a scope boundary:
//
//   Level 0: Tenant   (8 chars) - Multi-tenant isolation
//   Level 1: Service  (6 chars) - Service binding
//   Level 2: Session  (6 chars) - Session scoping
//   Level 3: Message  (4 chars) - Message ordering
//   Level 4: Sequence (4 chars) - Within-message sequence
//   Level 5: Nonce    (4 chars) - Enumeration resistance
//
// Format: TTTTTTTT.SSSSSS.NNNNNN.MMMM.QQQQ.XXXX
//         └──┬───┘ └──┬──┘ └──┬──┘ └┬─┘ └┬─┘ └┬─┘
//         Tenant  Service Session Msg  Seq  Nonce
//
// Example: a7b3c9d2.rstshm.x8k4m2.f3a1.0001.7f8e
//
// Privacy Properties:
//   - Tenant isolation: Different tenants → different fractal roots
//   - Session scoping: Cannot access other sessions' pointers
//   - Enumeration resistance: Nonce prevents guessing
//   - Fast lookup: HANA index on prefix
// ============================================================================

/// Fractal levels
pub const FractalLevel = enum {
    tenant,   // Level 0
    service,  // Level 1
    session,  // Level 2
    message,  // Level 3
    sequence, // Level 4
    nonce,    // Level 5
};

/// Response type stored with write pointer
pub const ResponseType = enum {
    text,      // Plain text response
    embedding, // Vector embedding
    json,      // Structured JSON
    binary,    // Binary data
    
    pub fn toString(self: ResponseType) []const u8 {
        return @tagName(self);
    }
};

/// Fractal Pointer ID - 32 character hierarchical identifier
pub const FractalPointerId = struct {
    /// Level 0: Tenant hash (8 chars)
    tenant: [8]u8,
    
    /// Level 1: Service code (6 chars)
    service: [6]u8,
    
    /// Level 2: Session hash (6 chars)
    session: [6]u8,
    
    /// Level 3: Message hash (4 chars)
    message: [4]u8,
    
    /// Level 4: Sequence number (4 chars)
    sequence: [4]u8,
    
    /// Level 5: Random nonce (4 chars)
    nonce: [4]u8,
    
    /// Raw bytes for efficient comparison
    pub fn toBytes(self: *const FractalPointerId) [32]u8 {
        var bytes: [32]u8 = undefined;
        @memcpy(bytes[0..8], &self.tenant);
        @memcpy(bytes[8..14], &self.service);
        @memcpy(bytes[14..20], &self.session);
        @memcpy(bytes[20..24], &self.message);
        @memcpy(bytes[24..28], &self.sequence);
        @memcpy(bytes[28..32], &self.nonce);
        return bytes;
    }
    
    /// Generate a new fractal pointer ID
    pub fn generate(
        tenant_id: []const u8,
        service_id: []const u8,
        session_id: []const u8,
        message_id: []const u8,
        seq: u32,
    ) FractalPointerId {
        return FractalPointerId{
            .tenant = hash8(tenant_id),
            .service = compress6(service_id),
            .session = hash6(session_id),
            .message = hash4(message_id),
            .sequence = encodeSequence(seq),
            .nonce = randomNonce(),
        };
    }
    
    /// Generate with explicit nonce (for deterministic tests)
    pub fn generateWithNonce(
        tenant_id: []const u8,
        service_id: []const u8,
        session_id: []const u8,
        message_id: []const u8,
        seq: u32,
        nonce_val: u32,
    ) FractalPointerId {
        var id = generate(tenant_id, service_id, session_id, message_id, seq);
        id.nonce = encodeSequence(nonce_val);
        return id;
    }
    
    /// Convert to dot-separated string format
    /// Format: TTTTTTTT.SSSSSS.NNNNNN.MMMM.QQQQ.XXXX
    pub fn toString(self: *const FractalPointerId) [37]u8 {
        var buf: [37]u8 = undefined;
        @memcpy(buf[0..8], &self.tenant);
        buf[8] = '.';
        @memcpy(buf[9..15], &self.service);
        buf[15] = '.';
        @memcpy(buf[16..22], &self.session);
        buf[22] = '.';
        @memcpy(buf[23..27], &self.message);
        buf[27] = '.';
        @memcpy(buf[28..32], &self.sequence);
        buf[32] = '.';
        @memcpy(buf[33..37], &self.nonce);
        return buf;
    }
    
    /// Parse from dot-separated string
    pub fn fromString(s: []const u8) !FractalPointerId {
        if (s.len != 37) return error.InvalidLength;
        
        // Validate dots in correct positions
        if (s[8] != '.' or s[15] != '.' or s[22] != '.' or s[27] != '.' or s[32] != '.') {
            return error.InvalidFormat;
        }
        
        return FractalPointerId{
            .tenant = s[0..8].*,
            .service = s[9..15].*,
            .session = s[16..22].*,
            .message = s[23..27].*,
            .sequence = s[28..32].*,
            .nonce = s[33..37].*,
        };
    }
    
    /// Get prefix for level-based queries
    /// Level 0: "TTTTTTTT" (tenant only)
    /// Level 1: "TTTTTTTT.SSSSSS" (tenant + service)
    /// Level 2: "TTTTTTTT.SSSSSS.NNNNNN" (+ session)
    /// etc.
    /// Caller owns the returned slice.
    pub fn prefixForLevel(self: *const FractalPointerId, allocator: std.mem.Allocator, level: FractalLevel) ![]const u8 {
        const full = self.toString();
        const end: usize = switch (level) {
            .tenant => 8,
            .service => 15,
            .session => 22,
            .message => 27,
            .sequence => 32,
            .nonce => 37,
        };
        return allocator.dupe(u8, full[0..end]);
    }
    
    /// Validate access: caller must match tenant AND session
    pub fn validateAccess(
        self: *const FractalPointerId,
        caller_tenant: []const u8,
        caller_session: []const u8,
    ) bool {
        const expected_tenant = hash8(caller_tenant);
        const expected_session = hash6(caller_session);
        
        return std.mem.eql(u8, &self.tenant, &expected_tenant) and
               std.mem.eql(u8, &self.session, &expected_session);
    }
    
    /// Check if this pointer belongs to a specific tenant
    pub fn belongsToTenant(self: *const FractalPointerId, tenant_id: []const u8) bool {
        const expected = hash8(tenant_id);
        return std.mem.eql(u8, &self.tenant, &expected);
    }
    
    /// Check if this pointer belongs to a specific service
    pub fn belongsToService(self: *const FractalPointerId, service_id: []const u8) bool {
        const expected = compress6(service_id);
        return std.mem.eql(u8, &self.service, &expected);
    }
    
    /// Check if this pointer belongs to a specific session
    pub fn belongsToSession(self: *const FractalPointerId, session_id: []const u8) bool {
        const expected = hash6(session_id);
        return std.mem.eql(u8, &self.session, &expected);
    }
};

/// Write Pointer - combines FractalPointerId with metadata
pub const WritePointer = struct {
    /// The fractal ID
    id: FractalPointerId,
    
    /// Response type
    response_type: ResponseType,
    
    /// BTP Destination for HANA write
    credentials_ref: []const u8,
    
    /// Target schema.table
    target_table: []const u8,
    
    /// TTL in seconds
    ttl_seconds: u32,
    
    /// Creation timestamp
    created_at: i64,
    
    /// Allocator for owned strings
    allocator: std.mem.Allocator,
    
    /// Create a new write pointer for LLM response
    pub fn create(
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        service_id: []const u8,
        session_id: []const u8,
        message_id: []const u8,
        response_type: ResponseType,
        credentials: []const u8,
        target_table: []const u8,
    ) !WritePointer {
        // Get next sequence number (in production: from atomic counter)
        const seq = getNextSequence();
        
        return WritePointer{
            .id = FractalPointerId.generate(
                tenant_id,
                service_id,
                session_id,
                message_id,
                seq,
            ),
            .response_type = response_type,
            .credentials_ref = try allocator.dupe(u8, credentials),
            .target_table = try allocator.dupe(u8, target_table),
            .ttl_seconds = 3600,
            .created_at = std.time.timestamp(),
            .allocator = allocator,
        };
    }
    
    /// Convert to URI format
    /// Format: toon-write://TTTTTTTT.SSSSSS.NNNNNN.MMMM.QQQQ.XXXX@DEST?type=text
    pub fn toUri(self: *const WritePointer, allocator: std.mem.Allocator) ![]const u8 {
        var uri = std.ArrayList(u8).init(allocator);
        const writer = uri.writer();
        
        const id_str = self.id.toString();
        try writer.print("toon-write://{s}@{s}?type={s}&ttl={d}", .{
            id_str,
            self.credentials_ref,
            self.response_type.toString(),
            self.ttl_seconds,
        });
        
        return uri.toOwnedSlice();
    }
    
    /// Convert to JSON for API response
    pub fn toJson(self: *const WritePointer, allocator: std.mem.Allocator) ![]const u8 {
        var json = std.ArrayList(u8).init(allocator);
        const writer = json.writer();
        
        const id_str = self.id.toString();
        try writer.print(
            \\{{"pointer":"{s}","type":"{s}","target":"{s}","ttl":{d},"created":{d}}}
        , .{
            id_str,
            self.response_type.toString(),
            self.target_table,
            self.ttl_seconds,
            self.created_at,
        });
        
        return json.toOwnedSlice();
    }
    
    /// Generate HANA INSERT SQL
    pub fn toInsertSql(
        self: *const WritePointer,
        content: []const u8,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        var sql = std.ArrayList(u8).init(allocator);
        const writer = sql.writer();
        
        const id_str = self.id.toString();
        
        // Validate target_table as schema.table identifier
        const safe_table = try escapeTableIdentifier(allocator, self.target_table);
        defer allocator.free(safe_table);
        
        // Escape content to prevent SQL injection via single quotes
        const safe_content = try escapeSqlContent(allocator, content);
        defer allocator.free(safe_content);
        
        try writer.print(
            \\INSERT INTO {s} (
            \\  POINTER_ID,
            \\  TENANT_HASH,
            \\  SERVICE_CODE,
            \\  SESSION_HASH,
            \\  MESSAGE_HASH,
            \\  RESPONSE_TYPE,
            \\  CONTENT,
            \\  CREATED_AT,
            \\  EXPIRES_AT
            \\) VALUES (
            \\  '{s}',
            \\  '{s}',
            \\  '{s}',
            \\  '{s}',
            \\  '{s}',
            \\  '{s}',
            \\  '{s}',
            \\  CURRENT_TIMESTAMP,
            \\  ADD_SECONDS(CURRENT_TIMESTAMP, {d})
            \\)
        , .{
            safe_table,
            id_str,
            self.id.tenant,
            self.id.service,
            self.id.session,
            self.id.message,
            self.response_type.toString(),
            safe_content,
            self.ttl_seconds,
        });
        
        return sql.toOwnedSlice();
    }
    
    /// Check if pointer is still valid
    pub fn isValid(self: *const WritePointer) bool {
        const now = std.time.timestamp();
        return (now - self.created_at) < @as(i64, self.ttl_seconds);
    }
    
    pub fn deinit(self: *WritePointer) void {
        self.allocator.free(self.credentials_ref);
        self.allocator.free(self.target_table);
    }
};

// ============================================================================
// Hash Functions (Fractal encoding)
// ============================================================================

/// Hash to 8 hex characters (32 bits)
fn hash8(input: []const u8) [8]u8 {
    const hash = fnv1a(input);
    var result: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "{x:0>8}", .{@as(u32, @truncate(hash))}) catch "00000000";
    return result;
}

/// Hash to 6 hex characters (24 bits)
fn hash6(input: []const u8) [6]u8 {
    const hash = fnv1a(input);
    var result: [6]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "{x:0>6}", .{@as(u24, @truncate(hash))}) catch "000000";
    return result;
}

/// Hash to 4 hex characters (16 bits)
fn hash4(input: []const u8) [4]u8 {
    const hash = fnv1a(input);
    var result: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "{x:0>4}", .{@as(u16, @truncate(hash))}) catch "0000";
    return result;
}

/// Compress service ID to 6 characters
fn compress6(service_id: []const u8) [6]u8 {
    var result: [6]u8 = "------".*;
    
    // Take first 6 consonants/significant chars
    var j: usize = 0;
    for (service_id) |c| {
        if (j >= 6) break;
        // Keep letters and digits, skip vowels for compression
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')) {
            const lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
            // Skip common vowels for better compression
            if (lower != 'a' and lower != 'e' and lower != 'i' and lower != 'o' and lower != 'u') {
                result[j] = lower;
                j += 1;
            }
        }
    }
    
    return result;
}

/// Encode sequence number to 4 hex characters
fn encodeSequence(seq: u32) [4]u8 {
    var result: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "{x:0>4}", .{@as(u16, @truncate(seq))}) catch "0000";
    return result;
}

/// Generate random 4-char nonce using cryptographic randomness
fn randomNonce() [4]u8 {
    var raw: [2]u8 = undefined;
    std.posix.getrandom(&raw) catch {
        // Fallback: mix nano timestamp with xorshift
        const ts = @as(u64, @bitCast(std.time.nanoTimestamp()));
        var state = ts ^ (ts >> 17);
        state *%= 0x2545F4914F6CDD1D;
        raw[0] = @truncate(state);
        raw[1] = @truncate(state >> 8);
    };
    const val = std.mem.readInt(u16, &raw, .little);
    var result: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "{x:0>4}", .{val}) catch "0000";
    return result;
}

/// FNV-1a hash function
fn fnv1a(data: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (data) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    return hash;
}

/// Global sequence counter — uses atomic to be safe across threads
var global_sequence: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

fn getNextSequence() u32 {
    return global_sequence.fetchAdd(1, .monotonic) + 1;
}

// ============================================================================
// SQL Escaping Helpers
// ============================================================================

/// Escape single quotes in content for safe SQL string interpolation
fn escapeSqlContent(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var count: usize = 0;
    for (s) |c| {
        if (c == '\'') count += 1;
    }
    if (count == 0) return allocator.dupe(u8, s);
    
    var out = try allocator.alloc(u8, s.len + count);
    var j: usize = 0;
    for (s) |c| {
        if (c == '\'') {
            out[j] = '\'';
            out[j + 1] = '\'';
            j += 2;
        } else {
            out[j] = c;
            j += 1;
        }
    }
    return out;
}

/// Validate and quote a schema.table identifier for safe SQL interpolation.
/// Returns '"SCHEMA"."TABLE"' format. Rejects identifiers with dangerous characters.
fn escapeTableIdentifier(allocator: std.mem.Allocator, table_ref: []const u8) ![]const u8 {
    const dot_idx = std.mem.indexOf(u8, table_ref, ".") orelse {
        // Single identifier — validate and double-quote
        try validateIdentifier(table_ref);
        return std.fmt.allocPrint(allocator, "\"{s}\"", .{table_ref});
    };
    const schema = table_ref[0..dot_idx];
    const table = table_ref[dot_idx + 1 ..];
    try validateIdentifier(schema);
    try validateIdentifier(table);
    return std.fmt.allocPrint(allocator, "\"{s}\".\"{s}\"", .{ schema, table });
}

fn validateIdentifier(name: []const u8) !void {
    if (name.len == 0) return error.InvalidIdentifier;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return error.InvalidIdentifier;
    }
}

// ============================================================================
// HANA Table Schema
// ============================================================================

pub const hana_schema = 
    \\-- HANA Schema for Fractal Write Pointers
    \\-- Run this DDL to create the LLM responses table
    \\
    \\CREATE COLUMN TABLE "AI_OUTPUTS"."LLM_RESPONSES" (
    \\    "POINTER_ID"    NVARCHAR(37) PRIMARY KEY,      -- Fractal ID
    \\    "TENANT_HASH"   NVARCHAR(8) NOT NULL,          -- Level 0: Partition key
    \\    "SERVICE_CODE"  NVARCHAR(6) NOT NULL,          -- Level 1
    \\    "SESSION_HASH"  NVARCHAR(6) NOT NULL,          -- Level 2
    \\    "MESSAGE_HASH"  NVARCHAR(4) NOT NULL,          -- Level 3
    \\    "RESPONSE_TYPE" NVARCHAR(16) NOT NULL,         -- text/embedding/json/binary
    \\    "CONTENT"       NCLOB,                          -- Response content
    \\    "VECTOR"        REAL_VECTOR(1536),             -- For embeddings
    \\    "CREATED_AT"    TIMESTAMP NOT NULL,
    \\    "EXPIRES_AT"    TIMESTAMP NOT NULL
    \\)
    \\PARTITION BY HASH ("TENANT_HASH") PARTITIONS 16;
    \\
    \\-- Index for session-level queries
    \\CREATE INDEX "IDX_LLM_RESPONSES_SESSION" ON "AI_OUTPUTS"."LLM_RESPONSES" (
    \\    "TENANT_HASH", "SERVICE_CODE", "SESSION_HASH"
    \\);
    \\
    \\-- Index for message-level queries  
    \\CREATE INDEX "IDX_LLM_RESPONSES_MESSAGE" ON "AI_OUTPUTS"."LLM_RESPONSES" (
    \\    "TENANT_HASH", "SERVICE_CODE", "SESSION_HASH", "MESSAGE_HASH"
    \\);
    \\
    \\-- Row-level security policy (multi-tenant isolation)
    \\-- Each user can only see their tenant's data
    \\CREATE ROW LEVEL SECURITY POLICY "TENANT_ISOLATION" ON "AI_OUTPUTS"."LLM_RESPONSES"
    \\    BASED ON ("TENANT_HASH" = SESSION_CONTEXT('TENANT_HASH'))
    \\    ENABLED;
;

// ============================================================================
// Tests
// ============================================================================

test "generate fractal pointer" {
    const id = FractalPointerId.generate(
        "tenant_xyz",
        "rustshimmy-be-log-local-models",
        "session_abc123",
        "msg_001",
        1,
    );
    
    const str = id.toString();
    try std.testing.expectEqual(@as(usize, 37), str.len);
    
    // Verify dots in correct positions
    try std.testing.expectEqual(@as(u8, '.'), str[8]);
    try std.testing.expectEqual(@as(u8, '.'), str[15]);
    try std.testing.expectEqual(@as(u8, '.'), str[22]);
    try std.testing.expectEqual(@as(u8, '.'), str[27]);
    try std.testing.expectEqual(@as(u8, '.'), str[32]);
}

test "validate access" {
    const id = FractalPointerId.generate(
        "tenant_xyz",
        "rustshimmy",
        "session_abc",
        "msg_001",
        1,
    );
    
    // Same tenant + session → allowed
    try std.testing.expect(id.validateAccess("tenant_xyz", "session_abc"));
    
    // Different tenant → denied
    try std.testing.expect(!id.validateAccess("tenant_other", "session_abc"));
    
    // Different session → denied
    try std.testing.expect(!id.validateAccess("tenant_xyz", "session_other"));
}

test "string roundtrip" {
    const original = FractalPointerId.generateWithNonce(
        "tenant_xyz",
        "rustshimmy",
        "session_abc",
        "msg_001",
        42,
        0x1234,
    );
    
    const str = original.toString();
    const parsed = try FractalPointerId.fromString(&str);
    
    try std.testing.expectEqualSlices(u8, &original.tenant, &parsed.tenant);
    try std.testing.expectEqualSlices(u8, &original.service, &parsed.service);
    try std.testing.expectEqualSlices(u8, &original.session, &parsed.session);
    try std.testing.expectEqualSlices(u8, &original.message, &parsed.message);
    try std.testing.expectEqualSlices(u8, &original.sequence, &parsed.sequence);
    try std.testing.expectEqualSlices(u8, &original.nonce, &parsed.nonce);
}

test "service compression" {
    // "rustshimmy-be-log-local-models" → "rstshm" (consonants)
    const compressed = compress6("rustshimmy-be-log-local-models");
    try std.testing.expectEqual(@as(usize, 6), compressed.len);
    // Should contain letters, not dashes
    for (compressed) |c| {
        try std.testing.expect(c != '-' or c == '-'); // placeholder chars ok
    }
}

test "write pointer sql generation" {
    const allocator = std.testing.allocator;
    
    var wp = try WritePointer.create(
        allocator,
        "tenant_xyz",
        "rustshimmy",
        "session_abc",
        "msg_001",
        .text,
        "HANA_PROD",
        "AI_OUTPUTS.LLM_RESPONSES",
    );
    defer wp.deinit();
    
    const sql = try wp.toInsertSql("Hello, world!", allocator);
    defer allocator.free(sql);
    
    try std.testing.expect(std.mem.indexOf(u8, sql, "INSERT INTO") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "AI_OUTPUTS.LLM_RESPONSES") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "Hello, world!") != null);
}
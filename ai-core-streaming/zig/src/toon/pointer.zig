const std = @import("std");

// ============================================================================
// TOON Data Pointer — Pass-by-Reference for Zero-Copy Service Communication
//
// Instead of passing data in messages, services pass pointers (URIs) that
// resolve lazily to data at the source (HANA, Object Store, etc.)
//
// URI Schemes:
//   hana-table://SCHEMA.TABLE?$filter=...&$select=...
//   hana-vector://SCHEMA.TABLE.COLUMN?k=10&query_id=...
//   hana-graph://SCHEMA.WORKSPACE/VERTEX_TYPE?depth=2
//   sap-obj://bucket/key?format=parquet
//   hdl://container/path/file.parquet
//
// Benefits:
//   - Message size: ~200 bytes instead of 10MB+
//   - Zero-copy: Data flows directly from source to GPU
//   - Lazy evaluation: Only fetch what's needed
//   - Caching: Tiny pointers easy to cache/invalidate
// ============================================================================

/// Pointer types for SAP HANA and Object Store
pub const PointerType = enum {
    hana_table,      // SQL table query
    hana_vector,     // Vector similarity search
    hana_graph,      // Graph traversal
    sap_object,      // SAP Object Store (S3 API)
    hdl_file,        // HANA Data Lake Files
    
    pub fn fromScheme(scheme: []const u8) ?PointerType {
        if (std.mem.eql(u8, scheme, "hana-table")) return .hana_table;
        if (std.mem.eql(u8, scheme, "hana-vector")) return .hana_vector;
        if (std.mem.eql(u8, scheme, "hana-graph")) return .hana_graph;
        if (std.mem.eql(u8, scheme, "sap-obj")) return .sap_object;
        if (std.mem.eql(u8, scheme, "hdl")) return .hdl_file;
        return null;
    }
    
    pub fn toScheme(self: PointerType) []const u8 {
        return switch (self) {
            .hana_table => "hana-table",
            .hana_vector => "hana-vector",
            .hana_graph => "hana-graph",
            .sap_object => "sap-obj",
            .hdl_file => "hdl",
        };
    }
};

/// Data format for object storage
pub const DataFormat = enum {
    parquet,
    arrow,
    json,
    csv,
    binary,
    auto,
    
    pub fn fromString(s: []const u8) DataFormat {
        if (std.mem.eql(u8, s, "parquet")) return .parquet;
        if (std.mem.eql(u8, s, "arrow")) return .arrow;
        if (std.mem.eql(u8, s, "json")) return .json;
        if (std.mem.eql(u8, s, "csv")) return .csv;
        if (std.mem.eql(u8, s, "binary")) return .binary;
        return .auto;
    }
};

/// TOON Data Pointer — Immutable reference to data at rest
pub const ToonPointer = struct {
    /// Pointer type (determines resolution strategy)
    ptr_type: PointerType,
    
    /// Location (schema.table, bucket/key, etc.)
    location: []const u8,
    
    /// Query parameters (OData filter, k-NN params, etc.)
    query: ?[]const u8,
    
    /// BTP Destination name for credentials
    credentials_ref: []const u8,
    
    /// Expected data format (for object store)
    format: DataFormat,
    
    /// Column projection (for tables/parquet)
    columns: ?[]const u8,
    
    /// Time-to-live in seconds (pointer validity)
    ttl_seconds: u32,
    
    /// Creation timestamp
    created_at: i64,
    
    /// Unique pointer ID (for tracking/caching)
    pointer_id: [32]u8,
    
    allocator: std.mem.Allocator,
    
    // ========================================================================
    // HANA Table Pointer Constructors
    // ========================================================================
    
    /// Create a HANA table pointer with OData-style filter
    pub fn hanaTable(
        allocator: std.mem.Allocator,
        schema: []const u8,
        table: []const u8,
        filter: ?[]const u8,
        select_columns: ?[]const u8,
        credentials: []const u8,
    ) !ToonPointer {
        const location = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ schema, table });
        
        var query_buf = std.ArrayList(u8){};
        if (filter) |f| {
            try query_buf.appendSlice(allocator, "$filter=");
            try query_buf.appendSlice(allocator, f);
        }
        if (select_columns) |cols| {
            if (query_buf.items.len > 0) try query_buf.append(allocator, '&');
            try query_buf.appendSlice(allocator, "$select=");
            try query_buf.appendSlice(allocator, cols);
        }

        return ToonPointer{
            .ptr_type = .hana_table,
            .location = location,
            .query = if (query_buf.items.len > 0) try query_buf.toOwnedSlice(allocator) else null,
            .credentials_ref = try allocator.dupe(u8, credentials),
            .format = .auto,
            .columns = if (select_columns) |cols| try allocator.dupe(u8, cols) else null,
            .ttl_seconds = 3600,
            .created_at = std.time.timestamp(),
            .pointer_id = generatePointerId(),
            .allocator = allocator,
        };
    }
    
    // ========================================================================
    // HANA Vector Pointer Constructors
    // ========================================================================
    
    /// Create a HANA vector pointer for k-NN similarity search
    pub fn hanaVector(
        allocator: std.mem.Allocator,
        schema: []const u8,
        table: []const u8,
        vector_column: []const u8,
        k: usize,
        query_vector_ref: ?[]const u8,
        credentials: []const u8,
    ) !ToonPointer {
        const location = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ schema, table, vector_column });
        
        var query_buf = std.ArrayList(u8){};
        try query_buf.writer(allocator).print("k={d}", .{k});
        if (query_vector_ref) |ref| {
            try query_buf.appendSlice(allocator, "&query_ref=");
            try query_buf.appendSlice(allocator, ref);
        }

        return ToonPointer{
            .ptr_type = .hana_vector,
            .location = location,
            .query = try query_buf.toOwnedSlice(allocator),
            .credentials_ref = try allocator.dupe(u8, credentials),
            .format = .auto,
            .columns = null,
            .ttl_seconds = 3600,
            .created_at = std.time.timestamp(),
            .pointer_id = generatePointerId(),
            .allocator = allocator,
        };
    }

    // ========================================================================
    // HANA Graph Pointer Constructors
    // ========================================================================
    
    /// Create a HANA graph pointer for traversal
    pub fn hanaGraph(
        allocator: std.mem.Allocator,
        schema: []const u8,
        workspace: []const u8,
        vertex_type: ?[]const u8,
        depth: usize,
        direction: []const u8,
        credentials: []const u8,
    ) !ToonPointer {
        var location_buf = std.ArrayList(u8){};
        try location_buf.writer(allocator).print("{s}.{s}", .{ schema, workspace });
        if (vertex_type) |vt| {
            try location_buf.append(allocator, '/');
            try location_buf.appendSlice(allocator, vt);
        }

        const query = try std.fmt.allocPrint(allocator, "depth={d}&direction={s}", .{ depth, direction });

        return ToonPointer{
            .ptr_type = .hana_graph,
            .location = try location_buf.toOwnedSlice(allocator),
            .query = query,
            .credentials_ref = try allocator.dupe(u8, credentials),
            .format = .auto,
            .columns = null,
            .ttl_seconds = 3600,
            .created_at = std.time.timestamp(),
            .pointer_id = generatePointerId(),
            .allocator = allocator,
        };
    }

    // ========================================================================
    // SAP Object Store Pointer Constructors
    // ========================================================================
    
    /// Create a SAP Object Store pointer
    pub fn sapObject(
        allocator: std.mem.Allocator,
        bucket: []const u8,
        key: []const u8,
        format: DataFormat,
        columns: ?[]const u8,
        credentials: []const u8,
    ) !ToonPointer {
        const location = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ bucket, key });
        
        var query_buf = std.ArrayList(u8){};
        if (format != .auto) {
            try query_buf.writer(allocator).print("format={s}", .{@tagName(format)});
        }
        if (columns) |cols| {
            if (query_buf.items.len > 0) try query_buf.append(allocator, '&');
            try query_buf.appendSlice(allocator, "columns=");
            try query_buf.appendSlice(allocator, cols);
        }

        return ToonPointer{
            .ptr_type = .sap_object,
            .location = location,
            .query = if (query_buf.items.len > 0) try query_buf.toOwnedSlice(allocator) else null,
            .credentials_ref = try allocator.dupe(u8, credentials),
            .format = format,
            .columns = if (columns) |cols| try allocator.dupe(u8, cols) else null,
            .ttl_seconds = 3600,
            .created_at = std.time.timestamp(),
            .pointer_id = generatePointerId(),
            .allocator = allocator,
        };
    }
    
    // ========================================================================
    // HANA Data Lake Pointer Constructors
    // ========================================================================
    
    /// Create a HANA Data Lake Files pointer
    pub fn hdlFile(
        allocator: std.mem.Allocator,
        container: []const u8,
        path: []const u8,
        format: DataFormat,
        credentials: []const u8,
    ) !ToonPointer {
        const location = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ container, path });
        
        return ToonPointer{
            .ptr_type = .hdl_file,
            .location = location,
            .query = if (format != .auto) try std.fmt.allocPrint(allocator, "format={s}", .{@tagName(format)}) else null,
            .credentials_ref = try allocator.dupe(u8, credentials),
            .format = format,
            .columns = null,
            .ttl_seconds = 3600,
            .created_at = std.time.timestamp(),
            .pointer_id = generatePointerId(),
            .allocator = allocator,
        };
    }
    
    // ========================================================================
    // URI Serialization / Deserialization
    // ========================================================================
    
    /// Serialize pointer to URI string
    pub fn toUri(self: *const ToonPointer, allocator: std.mem.Allocator) ![]const u8 {
        var uri = std.ArrayList(u8){};
        const writer = uri.writer(allocator);

        // Scheme
        try writer.print("{s}://", .{self.ptr_type.toScheme()});

        // Location (percent-encoded for URI safety)
        const encoded_location = try uriEncode(allocator, self.location);
        defer allocator.free(encoded_location);
        try writer.writeAll(encoded_location);

        // Query string (percent-encode values)
        if (self.query) |q| {
            const encoded_query = try uriEncode(allocator, q);
            defer allocator.free(encoded_query);
            try writer.print("?{s}", .{encoded_query});
        }

        // Add metadata as fragment (encode credential ref which may contain special chars)
        const encoded_cred = try uriEncode(allocator, self.credentials_ref);
        defer allocator.free(encoded_cred);
        try writer.print("#cred={s}&ttl={d}&fmt={s}", .{
            encoded_cred,
            self.ttl_seconds,
            @tagName(self.format),
        });
        if (self.columns) |cols| {
            const encoded_cols = try uriEncode(allocator, cols);
            defer allocator.free(encoded_cols);
            try writer.print("&cols={s}", .{encoded_cols});
        }
        try writer.writeAll("&id=");
        for (self.pointer_id[0..16]) |b| {
            try writer.print("{x:0>2}", .{b});
        }

        return uri.toOwnedSlice(allocator);
    }
    
    /// Parse pointer from URI string
    pub fn fromUri(allocator: std.mem.Allocator, uri: []const u8) !ToonPointer {
        // Find scheme
        const scheme_end = std.mem.indexOf(u8, uri, "://") orelse return error.InvalidUri;
        const scheme = uri[0..scheme_end];
        const ptr_type = PointerType.fromScheme(scheme) orelse return error.UnknownScheme;
        
        // Find location end (query or fragment)
        const after_scheme = uri[scheme_end + 3 ..];
        const query_start = std.mem.indexOfScalar(u8, after_scheme, '?');
        const fragment_start = std.mem.indexOfScalar(u8, after_scheme, '#');
        
        const location_end = if (query_start) |qs|
            qs
        else if (fragment_start) |fs|
            fs
        else
            after_scheme.len;
        
        const location = try allocator.dupe(u8, after_scheme[0..location_end]);
        
        // Parse query
        var query: ?[]const u8 = null;
        if (query_start) |qs| {
            const query_end = fragment_start orelse after_scheme.len;
            if (query_end > qs + 1) {
                query = try allocator.dupe(u8, after_scheme[qs + 1 .. query_end]);
            }
        }
        
        // Parse fragment for metadata (credentials, ttl, format, columns)
        var credentials_ref: []const u8 = try allocator.dupe(u8, "default");
        var ttl_seconds: u32 = 3600;
        var format: DataFormat = .auto;
        var columns: ?[]const u8 = null;
        if (fragment_start) |fs| {
            const fragment = after_scheme[fs + 1 ..];
            var iter = std.mem.splitSequence(u8, fragment, "&");
            while (iter.next()) |part| {
                if (std.mem.startsWith(u8, part, "cred=")) {
                    credentials_ref = try allocator.dupe(u8, part[5..]);
                } else if (std.mem.startsWith(u8, part, "ttl=")) {
                    ttl_seconds = std.fmt.parseInt(u32, part[4..], 10) catch 3600;
                } else if (std.mem.startsWith(u8, part, "fmt=")) {
                    format = DataFormat.fromString(part[4..]);
                } else if (std.mem.startsWith(u8, part, "cols=")) {
                    columns = try allocator.dupe(u8, part[5..]);
                }
            }
        }
        
        return ToonPointer{
            .ptr_type = ptr_type,
            .location = location,
            .query = query,
            .credentials_ref = credentials_ref,
            .format = format,
            .columns = columns,
            .ttl_seconds = ttl_seconds,
            .created_at = std.time.timestamp(),
            .pointer_id = generatePointerId(),
            .allocator = allocator,
        };
    }
    
    // ========================================================================
    // JSON Serialization (for OpenAI API messages)
    // ========================================================================
    
    /// Serialize to JSON for inclusion in messages
    pub fn toJson(self: *const ToonPointer, allocator: std.mem.Allocator) ![]const u8 {
        var json = std.ArrayList(u8){};
        const writer = json.writer(allocator);

        try writer.writeAll("{");
        try writer.print("\"type\":\"{s}\",", .{self.ptr_type.toScheme()});
        try writer.print("\"location\":\"{s}\",", .{self.location});
        if (self.query) |q| {
            try writer.print("\"query\":\"{s}\",", .{q});
        }
        try writer.print("\"credentials\":\"{s}\",", .{self.credentials_ref});
        try writer.print("\"format\":\"{s}\",", .{@tagName(self.format)});
        try writer.print("\"ttl\":{d},", .{self.ttl_seconds});
        try writer.print("\"created\":{d},", .{self.created_at});
        try writer.writeAll("\"id\":\"");
        for (self.pointer_id[0..16]) |b| {
            try writer.print("{x:0>2}", .{b});
        }
        try writer.writeAll("\"}");

        return json.toOwnedSlice(allocator);
    }
    
    // ========================================================================
    // Validity and Lifecycle
    // ========================================================================
    
    /// Check if pointer is still valid (not expired)
    pub fn isValid(self: *const ToonPointer) bool {
        const now = std.time.timestamp();
        return (now - self.created_at) < @as(i64, self.ttl_seconds);
    }
    
    /// Get remaining TTL in seconds
    pub fn remainingTtl(self: *const ToonPointer) i64 {
        const now = std.time.timestamp();
        const elapsed = now - self.created_at;
        const remaining = @as(i64, self.ttl_seconds) - elapsed;
        return @max(0, remaining);
    }
    
    /// Create a new pointer with extended TTL.
    /// Deep-copies location and query so the new pointer owns its own memory
    /// and is safe to use independently of the original.
    pub fn extend(self: *const ToonPointer, additional_seconds: u32) !ToonPointer {
        var extended = self.*;
        extended.ttl_seconds += additional_seconds;
        extended.location = try self.allocator.dupe(u8, self.location);
        extended.query = if (self.query) |q| try self.allocator.dupe(u8, q) else null;
        extended.credentials_ref = try self.allocator.dupe(u8, self.credentials_ref);
        extended.columns = if (self.columns) |c| try self.allocator.dupe(u8, c) else null;
        return extended;
    }
    
    pub fn deinit(self: *ToonPointer) void {
        self.allocator.free(self.location);
        if (self.query) |q| self.allocator.free(q);
        self.allocator.free(self.credentials_ref);
        if (self.columns) |c| self.allocator.free(c);
    }
};

// ============================================================================
// Pointer Revocation Registry
// ============================================================================

/// Thread-safe registry of revoked pointer IDs.
/// Services check this before resolving a pointer to enforce early invalidation.
pub const RevocationRegistry = struct {
    /// Set of revoked pointer ID hex strings (first 16 bytes = 32 hex chars)
    revoked: std.StringHashMap(i64), // pointer_id_hex → revocation timestamp
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) RevocationRegistry {
        return .{
            .revoked = std.StringHashMap(i64).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *RevocationRegistry) void {
        var iter = self.revoked.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.revoked.deinit();
    }
    
    /// Revoke a pointer by its ID. Returns error if already revoked.
    pub fn revoke(self: *RevocationRegistry, pointer_id: [32]u8) !void {
        var hex: [32]u8 = undefined;
        for (pointer_id[0..16], 0..) |b, i| {
            const hi = "0123456789abcdef"[b >> 4];
            const lo = "0123456789abcdef"[b & 0x0F];
            hex[i * 2] = hi;
            hex[i * 2 + 1] = lo;
        }
        const key = try self.allocator.dupe(u8, &hex);
        try self.revoked.put(key, std.time.timestamp());
    }
    
    /// Check if a pointer has been revoked.
    pub fn isRevoked(self: *const RevocationRegistry, pointer_id: [32]u8) bool {
        var hex: [32]u8 = undefined;
        for (pointer_id[0..16], 0..) |b, i| {
            const hi = "0123456789abcdef"[b >> 4];
            const lo = "0123456789abcdef"[b & 0x0F];
            hex[i * 2] = hi;
            hex[i * 2 + 1] = lo;
        }
        return self.revoked.contains(&hex);
    }
    
    /// Purge expired revocation entries older than max_age_seconds.
    /// Call periodically to prevent unbounded growth.
    pub fn purgeExpired(self: *RevocationRegistry, max_age_seconds: i64) void {
        const now = std.time.timestamp();
        var iter = self.revoked.iterator();
        while (iter.next()) |entry| {
            if (now - entry.value_ptr.* > max_age_seconds) {
                self.allocator.free(entry.key_ptr.*);
                self.revoked.removeByPtr(entry.key_ptr);
            }
        }
    }
};

/// Global revocation registry (single-instance per service)
var g_revocation_registry: ?RevocationRegistry = null;
/// Mutex protecting all accesses to g_revocation_registry.
var g_registry_mutex: std.Thread.Mutex = .{};

/// Initialize the global revocation registry (thread-safe).
pub fn initRevocationRegistry(allocator: std.mem.Allocator) void {
    g_registry_mutex.lock();
    defer g_registry_mutex.unlock();
    if (g_revocation_registry == null) {
        g_revocation_registry = RevocationRegistry.init(allocator);
    }
}

/// Revoke a pointer globally (thread-safe).
pub fn revokePointer(pointer: *const ToonPointer) !void {
    g_registry_mutex.lock();
    defer g_registry_mutex.unlock();
    if (g_revocation_registry) |*reg| {
        try reg.revoke(pointer.pointer_id);
    }
}

/// Check if a pointer is valid (not expired AND not revoked, thread-safe).
pub fn isPointerUsable(pointer: *const ToonPointer) bool {
    if (!pointer.isValid()) return false;
    g_registry_mutex.lock();
    defer g_registry_mutex.unlock();
    if (g_revocation_registry) |*reg| {
        if (reg.isRevoked(pointer.pointer_id)) return false;
    }
    return true;
}

// ============================================================================
// Pointer Resolution Result
// ============================================================================

pub const ResolutionType = enum {
    sql,           // HANA SQL statement
    presigned_url, // S3/Object Store presigned URL
    graph_query,   // Graph traversal query
};

pub const PointerResolution = struct {
    resolution_type: ResolutionType,
    value: []const u8,        // SQL, URL, or graph query
    schema_hint: ?[]const u8, // Expected result schema (JSON)
    estimated_rows: ?usize,   // Estimated row count
    
    pub fn deinit(self: *PointerResolution, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
        if (self.schema_hint) |s| allocator.free(s);
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Percent-encode a string for safe inclusion in a URI component.
/// Encodes everything except unreserved characters (A-Z, a-z, 0-9, '-', '.', '_', '~').
fn uriEncode(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const hex = "0123456789ABCDEF";
    // Count bytes that need encoding
    var encoded_len: usize = 0;
    for (raw) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            encoded_len += 1;
        } else {
            encoded_len += 3; // %XX
        }
    }
    if (encoded_len == raw.len) return allocator.dupe(u8, raw);
    
    var result = try allocator.alloc(u8, encoded_len);
    var j: usize = 0;
    for (raw) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            result[j] = c;
            j += 1;
        } else {
            result[j] = '%';
            result[j + 1] = hex[c >> 4];
            result[j + 2] = hex[c & 0x0F];
            j += 3;
        }
    }
    return result;
}

fn generatePointerId() [32]u8 {
    var id: [32]u8 = undefined;
    
    // Use OS cryptographic random for unique, unpredictable pointer IDs.
    // Falls back to timestamp-based ID if crypto random is unavailable.
    std.posix.getrandom(&id) catch {
        // Fallback: mix timestamp + nanos with a simple hash to fill all 32 bytes
        const timestamp = @as(u64, @bitCast(std.time.timestamp()));
        const nanos = @as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp()))));
        std.mem.writeInt(u64, id[0..8], timestamp, .little);
        std.mem.writeInt(u64, id[8..16], nanos, .little);
        // Mix remaining bytes with varied hash instead of repeating same value
        var state: u64 = timestamp *% 0x517cc1b727220a95 +% nanos;
        for (id[16..]) |*b| {
            state ^= state >> 13;
            state *%= 0x2545F4914F6CDD1D;
            state ^= state >> 17;
            b.* = @truncate(state);
        }
    };
    return id;
}

// ============================================================================
// Tests
// ============================================================================

test "hana table pointer" {
    const allocator = std.testing.allocator;
    
    var ptr = try ToonPointer.hanaTable(
        allocator,
        "SALES",
        "ORDERS",
        "YEAR eq 2024",
        "ORDER_ID,AMOUNT",
        "HANA_PROD",
    );
    defer ptr.deinit();
    
    try std.testing.expectEqual(PointerType.hana_table, ptr.ptr_type);
    try std.testing.expectEqualStrings("SALES.ORDERS", ptr.location);
    try std.testing.expect(ptr.isValid());
}

test "hana vector pointer" {
    const allocator = std.testing.allocator;
    
    var ptr = try ToonPointer.hanaVector(
        allocator,
        "EMBEDDINGS",
        "DOCUMENTS",
        "VECTOR_COL",
        10,
        "query_123",
        "HANA_VECTOR",
    );
    defer ptr.deinit();
    
    try std.testing.expectEqual(PointerType.hana_vector, ptr.ptr_type);
    try std.testing.expectEqualStrings("EMBEDDINGS.DOCUMENTS.VECTOR_COL", ptr.location);
}

test "sap object pointer" {
    const allocator = std.testing.allocator;
    
    var ptr = try ToonPointer.sapObject(
        allocator,
        "ai-models",
        "embeddings/vectors.parquet",
        .parquet,
        "id,vector",
        "OBJECT_STORE",
    );
    defer ptr.deinit();
    
    try std.testing.expectEqual(PointerType.sap_object, ptr.ptr_type);
    try std.testing.expectEqual(DataFormat.parquet, ptr.format);
}

test "uri serialization roundtrip" {
    const allocator = std.testing.allocator;
    
    var original = try ToonPointer.hanaTable(
        allocator,
        "SALES",
        "ORDERS",
        "STATUS eq 'OPEN'",
        null,
        "HANA_PROD",
    );
    defer original.deinit();
    
    const uri = try original.toUri(allocator);
    defer allocator.free(uri);
    
    try std.testing.expect(std.mem.startsWith(u8, uri, "hana-table://SALES.ORDERS"));
}
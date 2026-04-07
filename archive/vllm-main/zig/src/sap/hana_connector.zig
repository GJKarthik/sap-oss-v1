const std = @import("std");
const toon_pointer = @import("toon_pointer.zig");

// ============================================================================
// HANA Connector — Resolve TOON Pointers to SAP HANA Cloud
//
// Supports:
//   - HANA Table: SQL SELECT with OData-style filters
//   - HANA Vector: k-NN similarity search with COSINE_SIMILARITY()
//   - HANA Graph: Graph traversal with MATCH patterns
//
// All operations use BTP Destinations for credential management.
// ============================================================================

/// HANA connection configuration from BTP Destination
pub const HanaConfig = struct {
    host: []const u8,
    port: u16,
    schema: []const u8,
    user: []const u8,
    password: []const u8,
    ssl_enabled: bool,
    
    /// Load from environment (BTP Destination binding).
    ///
    /// All string fields are heap-allocated via `allocator.dupe` for
    /// uniform ownership.  Call `deinit` to free them.
    pub fn fromEnv(allocator: std.mem.Allocator, destination_name: []const u8) !HanaConfig {
        _ = destination_name;

        return HanaConfig{
            .host = try allocator.dupe(u8, std.posix.getenv("HANA_HOST") orelse "localhost"),
            .port = if (std.posix.getenv("HANA_PORT")) |p|
                std.fmt.parseInt(u16, p, 10) catch 443
            else
                443,
            .schema = try allocator.dupe(u8, std.posix.getenv("HANA_SCHEMA") orelse "SYSTEM"),
            .user = try allocator.dupe(u8, std.posix.getenv("HANA_USER") orelse "SYSTEM"),
            .password = try allocator.dupe(u8, std.posix.getenv("HANA_PASSWORD") orelse ""),
            .ssl_enabled = if (std.posix.getenv("HANA_SSL")) |s|
                std.mem.eql(u8, s, "true")
            else
                true,
        };
    }

    /// Free all heap-allocated fields.
    pub fn deinit(self: *const HanaConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.schema);
        allocator.free(self.user);
        allocator.free(self.password);
    }
};

// ============================================================================
// SQL Escaping Utilities
// ============================================================================

/// Escape a SQL identifier by doubling internal double-quotes.
/// Returns a newly-allocated string: "MY""TABLE" (safe inside "...").
fn escapeIdentifier(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    // Reject empty identifiers
    if (raw.len == 0) return error.InvalidIdentifier;

    // Validate: identifiers must be alphanumeric, underscore, or dot
    for (raw) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.') {
            return error.InvalidIdentifier;
        }
    }

    // Reject SQL keywords to prevent injection via identifier names
    const sql_keywords = [_][]const u8{
        "SELECT", "DROP",     "DELETE",   "INSERT",
        "UPDATE", "ALTER",    "EXEC",     "EXECUTE",
        "TRUNCATE", "CREATE", "GRANT",    "REVOKE",
        "UNION",  "MERGE",    "CALL",
    };

    // Convert raw to uppercase for case-insensitive comparison
    var upper_buf = try allocator.alloc(u8, raw.len);
    defer allocator.free(upper_buf);
    for (raw, 0..) |c, idx| {
        upper_buf[idx] = std.ascii.toUpper(c);
    }

    for (sql_keywords) |kw| {
        if (std.mem.eql(u8, upper_buf, kw)) {
            return error.InvalidIdentifier;
        }
    }

    return allocator.dupe(u8, raw);
}

/// Escape a SQL string literal by doubling single-quotes.
/// Returns the escaped value (without surrounding quotes).
fn escapeSqlString(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var count: usize = 0;
    for (raw) |c| {
        if (c == '\'') count += 1;
    }
    if (count == 0) return allocator.dupe(u8, raw);
    
    var result = try allocator.alloc(u8, raw.len + count);
    var j: usize = 0;
    for (raw) |c| {
        if (c == '\'') {
            result[j] = '\'';
            j += 1;
        }
        result[j] = c;
        j += 1;
    }
    return result;
}

/// HANA Connector for pointer resolution
pub const HanaConnector = struct {
    allocator: std.mem.Allocator,
    config: HanaConfig,
    
    pub fn init(allocator: std.mem.Allocator, config: HanaConfig) HanaConnector {
        return HanaConnector{
            .allocator = allocator,
            .config = config,
        };
    }
    
    // ========================================================================
    // HANA Table Resolution (SQL SELECT)
    // ========================================================================
    
    /// Resolve a HANA table pointer to SQL
    pub fn resolveTable(self: *HanaConnector, ptr: *const toon_pointer.ToonPointer) !toon_pointer.PointerResolution {
        if (ptr.ptr_type != .hana_table) return error.WrongPointerType;
        
        var sql = std.ArrayList(u8){};
        const writer = sql.writer();
        
        // Parse location: SCHEMA.TABLE
        const dot_idx = std.mem.indexOf(u8, ptr.location, ".") orelse return error.InvalidLocation;
        const schema = ptr.location[0..dot_idx];
        const table = ptr.location[dot_idx + 1 ..];
        
        // Validate identifiers to prevent SQL injection
        const safe_schema = try escapeIdentifier(self.allocator, schema);
        defer self.allocator.free(safe_schema);
        const safe_table = try escapeIdentifier(self.allocator, table);
        defer self.allocator.free(safe_table);
        
        // Build SELECT
        try writer.writeAll("SELECT ");
        
        // Column projection (validate columns are safe identifiers)
        if (ptr.columns) |cols| {
            // Validate each column name in the comma-separated list
            var col_iter = std.mem.splitScalar(u8, cols, ',');
            var first = true;
            while (col_iter.next()) |col| {
                const trimmed = std.mem.trim(u8, col, " ");
                if (trimmed.len == 0) continue;
                if (!first) try writer.writeAll(",");
                if (std.mem.eql(u8, trimmed, "*")) {
                    try writer.writeAll("*");
                } else {
                    const safe_col = try escapeIdentifier(self.allocator, trimmed);
                    defer self.allocator.free(safe_col);
                    try writer.print("\"{s}\"", .{safe_col});
                }
                first = false;
            }
            if (first) try writer.writeAll("*"); // empty columns list → select all
        } else {
            try writer.writeAll("*");
        }
        
        try writer.print(" FROM \"{s}\".\"{s}\"", .{ safe_schema, safe_table });
        
        // Parse OData-style query to SQL WHERE
        if (ptr.query) |query| {
            if (try parseODataFilter(self.allocator, query)) |where_clause| {
                defer self.allocator.free(where_clause);
                try writer.print(" WHERE {s}", .{where_clause});
            }
        }
        
        return toon_pointer.PointerResolution{
            .resolution_type = .sql,
            .value = try sql.toOwnedSlice(),
            .schema_hint = null,
            .estimated_rows = null,
        };
    }
    
    // ========================================================================
    // HANA Vector Resolution (k-NN Similarity Search)
    // ========================================================================
    
    /// Resolve a HANA vector pointer to similarity search SQL
    pub fn resolveVector(self: *HanaConnector, ptr: *const toon_pointer.ToonPointer) !toon_pointer.PointerResolution {
        if (ptr.ptr_type != .hana_vector) return error.WrongPointerType;
        
        var sql = std.ArrayList(u8){};
        const writer = sql.writer();
        
        // Parse location: SCHEMA.TABLE.VECTOR_COLUMN
        var parts = std.mem.splitScalar(u8, ptr.location, '.');
        const schema = parts.next() orelse return error.InvalidLocation;
        const table = parts.next() orelse return error.InvalidLocation;
        const vector_col = parts.next() orelse return error.InvalidLocation;
        
        // Parse query parameters
        var k: usize = 10;
        var query_ref: ?[]const u8 = null;
        if (ptr.query) |query| {
            var params = std.mem.splitScalar(u8, query, '&');
            while (params.next()) |param| {
                if (std.mem.startsWith(u8, param, "k=")) {
                    k = std.fmt.parseInt(usize, param[2..], 10) catch 10;
                } else if (std.mem.startsWith(u8, param, "query_ref=")) {
                    query_ref = param[10..];
                }
            }
        }
        
        // Validate identifiers and escape string values to prevent SQL injection
        const safe_schema = try escapeIdentifier(self.allocator, schema);
        defer self.allocator.free(safe_schema);
        const safe_table = try escapeIdentifier(self.allocator, table);
        defer self.allocator.free(safe_table);
        const safe_vector_col = try escapeIdentifier(self.allocator, vector_col);
        defer self.allocator.free(safe_vector_col);
        const safe_query_ref = try escapeSqlString(self.allocator, query_ref orelse "default");
        defer self.allocator.free(safe_query_ref);
        
        // Build vector similarity SQL
        // Uses HANA's built-in COSINE_SIMILARITY function
        try writer.print(
            \\SELECT TOP {d} *,
            \\  COSINE_SIMILARITY("{s}", (SELECT "{s}" FROM "{s}"."{s}" WHERE ID = '{s}')) AS similarity
            \\FROM "{s}"."{s}"
            \\ORDER BY similarity DESC
        , .{
            k,
            safe_vector_col,
            safe_vector_col,
            safe_schema,
            safe_table,
            safe_query_ref,
            safe_schema,
            safe_table,
        });
        
        return toon_pointer.PointerResolution{
            .resolution_type = .sql,
            .value = try sql.toOwnedSlice(),
            .schema_hint = try self.allocator.dupe(u8, 
                \\{"columns":["*","similarity"],"types":["any","float"]}
            ),
            .estimated_rows = k,
        };
    }
    
    // ========================================================================
    // HANA Graph Resolution (Graph Traversal)
    // ========================================================================
    
    /// Resolve a HANA graph pointer to graph query SQL
    pub fn resolveGraph(self: *HanaConnector, ptr: *const toon_pointer.ToonPointer) !toon_pointer.PointerResolution {
        if (ptr.ptr_type != .hana_graph) return error.WrongPointerType;
        
        var sql = std.ArrayList(u8){};
        const writer = sql.writer();
        
        // Parse location: SCHEMA.WORKSPACE/VERTEX_TYPE
        const slash_idx = std.mem.indexOf(u8, ptr.location, "/");
        const dot_idx = std.mem.indexOf(u8, ptr.location, ".") orelse return error.InvalidLocation;
        
        const schema = ptr.location[0..dot_idx];
        const workspace_end = slash_idx orelse ptr.location.len;
        const workspace = ptr.location[dot_idx + 1 .. workspace_end];
        const vertex_type = if (slash_idx) |idx| ptr.location[idx + 1 ..] else null;
        
        // Validate identifiers to prevent injection
        const safe_schema = try escapeIdentifier(self.allocator, schema);
        defer self.allocator.free(safe_schema);
        const safe_workspace = try escapeIdentifier(self.allocator, workspace);
        defer self.allocator.free(safe_workspace);
        
        // Parse query parameters
        var depth: usize = 1;
        var direction: []const u8 = "outgoing";
        if (ptr.query) |query| {
            var params = std.mem.splitScalar(u8, query, '&');
            while (params.next()) |param| {
                if (std.mem.startsWith(u8, param, "depth=")) {
                    depth = std.fmt.parseInt(usize, param[6..], 10) catch 1;
                } else if (std.mem.startsWith(u8, param, "direction=")) {
                    direction = param[10..];
                }
            }
        }
        
        // Validate direction is one of the allowed values
        const valid_directions = [_][]const u8{ "outgoing", "out", "incoming", "in", "any" };
        var direction_valid = false;
        for (valid_directions) |valid| {
            if (std.mem.eql(u8, direction, valid)) {
                direction_valid = true;
                break;
            }
        }
        if (!direction_valid) direction = "outgoing";
        
        // Build HANA Graph MATCH query
        // Using HANA's OpenCypher-compatible graph engine
        try writer.print(
            \\GRAPH_WORKSPACE "{s}"."{s}"
            \\MATCH (n
        , .{ safe_schema, safe_workspace });
        
        if (vertex_type) |vt| {
            const safe_vt = try escapeIdentifier(self.allocator, vt);
            defer self.allocator.free(safe_vt);
            try writer.print(":{s}", .{safe_vt});
        }
        try writer.writeAll(")");
        
        // Add traversal pattern based on depth and direction
        // Each hop needs unique variable names: e1, m1, e2, m2, ...
        var d: usize = 0;
        while (d < depth) : (d += 1) {
            if (std.mem.eql(u8, direction, "outgoing") or std.mem.eql(u8, direction, "out")) {
                try writer.print("-[e{d}]->(m{d})", .{ d + 1, d + 1 });
            } else if (std.mem.eql(u8, direction, "incoming") or std.mem.eql(u8, direction, "in")) {
                try writer.print("<-[e{d}]-(m{d})", .{ d + 1, d + 1 });
            } else {
                try writer.print("-[e{d}]-(m{d})", .{ d + 1, d + 1 });
            }
        }
        
        // Build RETURN clause with all hop variables
        try writer.writeAll("\nRETURN n");
        var r: usize = 0;
        while (r < depth) : (r += 1) {
            try writer.print(", e{d}, m{d}", .{ r + 1, r + 1 });
        }
        
        // Build schema hint with all variable names
        var hint = std.ArrayList(u8){};
        const hw = hint.writer();
        try hw.writeAll("{\"columns\":[\"n\"");
        var h: usize = 0;
        while (h < depth) : (h += 1) {
            try hw.print(",\"e{d}\",\"m{d}\"", .{ h + 1, h + 1 });
        }
        try hw.writeAll("],\"types\":[\"vertex\"");
        h = 0;
        while (h < depth) : (h += 1) {
            try hw.writeAll(",\"edge\",\"vertex\"");
        }
        try hw.writeAll("]}");
        
        return toon_pointer.PointerResolution{
            .resolution_type = .graph_query,
            .value = try sql.toOwnedSlice(),
            .schema_hint = try hint.toOwnedSlice(),
            .estimated_rows = null,
        };
    }
    
    // ========================================================================
    // Universal Resolver
    // ========================================================================
    
    /// Resolve any HANA pointer type
    pub fn resolve(self: *HanaConnector, ptr: *const toon_pointer.ToonPointer) !toon_pointer.PointerResolution {
        return switch (ptr.ptr_type) {
            .hana_table => self.resolveTable(ptr),
            .hana_vector => self.resolveVector(ptr),
            .hana_graph => self.resolveGraph(ptr),
            else => error.UnsupportedPointerType,
        };
    }
};

// ============================================================================
// OData Filter to SQL WHERE Parser
// ============================================================================

/// Parse OData-style $filter to SQL WHERE clause
fn parseODataFilter(allocator: std.mem.Allocator, query: []const u8) !?[]const u8 {
    // Extract $filter value
    const filter_prefix = "$filter=";
    const filter_start = std.mem.indexOf(u8, query, filter_prefix) orelse return null;
    
    var filter_end = std.mem.indexOf(u8, query[filter_start..], "&");
    const filter_value = if (filter_end) |end|
        query[filter_start + filter_prefix.len .. filter_start + end]
    else
        query[filter_start + filter_prefix.len ..];
    
    if (filter_value.len == 0) return null;
    
    // Convert OData operators to SQL
    var result = std.ArrayList(u8){};
    const writer = result.writer();
    
    // OData operator replacement table: (pattern, sql_replacement)
    // Pattern lengths: " eq " = 4, " ne " = 4, " lt " = 4, " le " = 4,
    //                  " gt " = 4, " ge " = 4, " or " = 4, " and " = 5
    const replacements = [_]struct { pattern: []const u8, sql: []const u8 }{
        .{ .pattern = " eq ", .sql = " = " },
        .{ .pattern = " ne ", .sql = " <> " },
        .{ .pattern = " lt ", .sql = " < " },
        .{ .pattern = " le ", .sql = " <= " },
        .{ .pattern = " gt ", .sql = " > " },
        .{ .pattern = " ge ", .sql = " >= " },
        .{ .pattern = " and ", .sql = " AND " },
        .{ .pattern = " or ", .sql = " OR " },
    };
    
    var i: usize = 0;
    while (i < filter_value.len) {
        var matched = false;
        for (replacements) |rep| {
            if (i + rep.pattern.len <= filter_value.len and
                std.mem.eql(u8, filter_value[i..][0..rep.pattern.len], rep.pattern))
            {
                try writer.writeAll(rep.sql);
                i += rep.pattern.len;
                matched = true;
                break;
            }
        }
        if (!matched) {
            try writer.writeByte(filter_value[i]);
            i += 1;
        }
    }
    
    // Escape single quotes in values to prevent SQL injection in WHERE clause
    const raw_result = try result.toOwnedSlice();
    defer allocator.free(raw_result);
    return escapeSqlString(allocator, raw_result);
}

// ============================================================================
// Tests
// ============================================================================

test "resolve table pointer to SQL" {
    const allocator = std.testing.allocator;
    
    var ptr = try toon_pointer.ToonPointer.hanaTable(
        allocator,
        "SALES",
        "ORDERS",
        "YEAR eq 2024 and STATUS eq 'OPEN'",
        "ORDER_ID,AMOUNT,STATUS",
        "HANA_PROD",
    );
    defer ptr.deinit();
    
    const config = HanaConfig{
        .host = "localhost",
        .port = 443,
        .schema = "SALES",
        .user = "test",
        .password = "test",
        .ssl_enabled = true,
    };
    
    var connector = HanaConnector.init(allocator, config);
    var resolution = try connector.resolve(&ptr);
    defer resolution.deinit();
    
    try std.testing.expectEqual(toon_pointer.ResolutionType.sql, resolution.resolution_type);
    try std.testing.expect(std.mem.indexOf(u8, resolution.value, "SELECT") != null);
    try std.testing.expect(std.mem.indexOf(u8, resolution.value, "SALES") != null);
    try std.testing.expect(std.mem.indexOf(u8, resolution.value, "ORDERS") != null);
}

test "resolve vector pointer to similarity SQL" {
    const allocator = std.testing.allocator;
    
    var ptr = try toon_pointer.ToonPointer.hanaVector(
        allocator,
        "EMBEDDINGS",
        "DOCS",
        "VECTOR",
        5,
        "doc_123",
        "HANA_VECTOR",
    );
    defer ptr.deinit();
    
    const config = HanaConfig{
        .host = "localhost",
        .port = 443,
        .schema = "EMBEDDINGS",
        .user = "test",
        .password = "test",
        .ssl_enabled = true,
    };
    
    var connector = HanaConnector.init(allocator, config);
    var resolution = try connector.resolve(&ptr);
    defer resolution.deinit();
    
    try std.testing.expect(std.mem.indexOf(u8, resolution.value, "COSINE_SIMILARITY") != null);
    try std.testing.expect(std.mem.indexOf(u8, resolution.value, "TOP 5") != null);
}

test "resolve graph pointer" {
    const allocator = std.testing.allocator;
    
    var ptr = try toon_pointer.ToonPointer.hanaGraph(
        allocator,
        "NETWORK",
        "SOCIAL",
        "Person",
        2,
        "outgoing",
        "HANA_GRAPH",
    );
    defer ptr.deinit();
    
    const config = HanaConfig{
        .host = "localhost",
        .port = 443,
        .schema = "NETWORK",
        .user = "test",
        .password = "test",
        .ssl_enabled = true,
    };
    
    var connector = HanaConnector.init(allocator, config);
    var resolution = try connector.resolve(&ptr);
    defer resolution.deinit();
    
    try std.testing.expectEqual(toon_pointer.ResolutionType.graph_query, resolution.resolution_type);
    try std.testing.expect(std.mem.indexOf(u8, resolution.value, "GRAPH_WORKSPACE") != null);
    try std.testing.expect(std.mem.indexOf(u8, resolution.value, "MATCH") != null);
}

test "OData filter parsing" {
    const allocator = std.testing.allocator;

    const result = try parseODataFilter(allocator, "$filter=STATUS eq 'OPEN' and YEAR gt 2020");
    defer if (result) |r| allocator.free(r);

    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, " = ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, " AND ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, " > ") != null);
}

test "escapeIdentifier rejects SQL keywords" {
    const allocator = std.testing.allocator;

    // All SQL keywords (case-insensitive) should be rejected
    const keywords = [_][]const u8{ "SELECT", "select", "Select", "DROP", "drop", "DELETE", "INSERT", "UPDATE", "ALTER", "EXEC", "EXECUTE", "TRUNCATE", "CREATE", "GRANT", "REVOKE", "UNION", "MERGE", "CALL" };
    for (keywords) |kw| {
        const result = escapeIdentifier(allocator, kw);
        try std.testing.expectError(error.InvalidIdentifier, result);
    }

    // Valid identifiers should still pass
    const valid = try escapeIdentifier(allocator, "MY_TABLE");
    defer allocator.free(valid);
    try std.testing.expectEqualStrings("MY_TABLE", valid);
}
//! SAP HANA SQL-over-HTTP Client for Schema Discovery
//!
//! Queries SYS.TABLES, SYS.TABLE_COLUMNS, SYS.CONSTRAINTS, SYS.REFERENTIAL_CONSTRAINTS
//! to discover table schemas, columns, PKs, and FKs. Used to provide schema context
//! for PAL SQL CALL generation.
//!
//! Features (ported from search-svc):
//!   - OAuth 2.0 token acquisition and refresh
//!   - Connection pooling with keep-alive
//!   - Basic auth fallback
//!
//! Adapted from lang-be-po-gen-foundry/zig/src/hana.zig

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const schema_mod = @import("../mcp/schema.zig");

// ============================================================================
// OAuth 2.0 Token (ported from search-svc hana/rest_api.zig)
// ============================================================================

pub const OAuthToken = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_in: i64,
    acquired_at: i64,

    pub fn isExpired(self: OAuthToken) bool {
        const now = std.time.timestamp();
        const expires_at = self.acquired_at + self.expires_in - 60; // 60s buffer
        return now >= expires_at;
    }
};

pub const OAuthConfig = struct {
    client_id: []const u8,
    client_secret: []const u8,
    token_url: []const u8,

    pub fn fromEnv() OAuthConfig {
        return .{
            .client_id = std.posix.getenv("HANA_CLIENT_ID") orelse "",
            .client_secret = std.posix.getenv("HANA_CLIENT_SECRET") orelse "",
            .token_url = std.posix.getenv("HANA_TOKEN_URL") orelse "",
        };
    }

    pub fn isConfigured(self: OAuthConfig) bool {
        return self.client_id.len > 0 and self.client_secret.len > 0 and self.token_url.len > 0;
    }
};

// ============================================================================
// Connection Pool Entry
// ============================================================================

const PoolEntry = struct {
    sock: std.posix.socket_t,
    last_used: i64,
    in_use: bool,
};

const MAX_POOL_SIZE = 5;
const POOL_IDLE_TIMEOUT_S: i64 = 300; // 5 minutes

// ============================================================================
// HANA Client
// ============================================================================

pub const HanaClient = struct {
    allocator: Allocator,
    host: []const u8,
    port: u16,
    user: []const u8,
    password: []const u8,
    use_ssl: bool,
    oauth_config: OAuthConfig,
    oauth_token: ?OAuthToken,
    pool: [MAX_POOL_SIZE]?PoolEntry,

    pub fn init(
        allocator: Allocator,
        host: []const u8,
        port: u16,
        user: []const u8,
        password: []const u8,
        use_ssl: bool,
    ) HanaClient {
        return .{
            .allocator = allocator,
            .host = host,
            .port = port,
            .user = user,
            .password = password,
            .use_ssl = use_ssl,
            .oauth_config = OAuthConfig.fromEnv(),
            .oauth_token = null,
            .pool = .{null} ** MAX_POOL_SIZE,
        };
    }

    pub fn deinit(self: *HanaClient) void {
        // Close all pooled connections
        for (&self.pool) |*entry| {
            if (entry.*) |e| {
                std.posix.close(e.sock);
                entry.* = null;
            }
        }
    }

    pub fn isConfigured(self: *const HanaClient) bool {
        return self.host.len > 0 and self.user.len > 0;
    }

    // ========================================================================
    // OAuth 2.0 Token Management
    // ========================================================================

    /// Get a valid auth header — prefers OAuth, falls back to Basic auth
    fn getAuthHeader(self: *HanaClient, buf: []u8) ![]const u8 {
        // Try OAuth first
        if (self.oauth_config.isConfigured()) {
            if (self.oauth_token) |token| {
                if (!token.isExpired()) {
                    return std.fmt.bufPrint(buf, "Bearer {s}", .{token.access_token}) catch return error.AuthTooLong;
                }
            }
            // Token expired or missing — try to refresh
            self.acquireOAuthToken() catch |err| {
                std.log.warn("[hana] OAuth token acquisition failed: {} — falling back to Basic auth", .{err});
            };
            if (self.oauth_token) |token| {
                return std.fmt.bufPrint(buf, "Bearer {s}", .{token.access_token}) catch return error.AuthTooLong;
            }
        }

        // Basic auth fallback
        var auth_input_buf: [512]u8 = undefined;
        const auth_input = std.fmt.bufPrint(&auth_input_buf, "{s}:{s}", .{ self.user, self.password }) catch return error.AuthTooLong;
        var b64_buf: [1024]u8 = undefined;
        const b64_encoded = std.base64.standard.Encoder.encode(&b64_buf, auth_input);
        return std.fmt.bufPrint(buf, "Basic {s}", .{b64_encoded}) catch return error.AuthTooLong;
    }

    fn acquireOAuthToken(self: *HanaClient) !void {
        const cfg = self.oauth_config;
        if (!cfg.isConfigured()) return error.OAuthNotConfigured;

        // Build token request body
        var body_buf: std.ArrayList(u8) = .{};
        const bw = body_buf.writer(self.allocator);
        try bw.writeAll("grant_type=client_credentials&client_id=");
        try bw.writeAll(cfg.client_id);
        try bw.writeAll("&client_secret=");
        try bw.writeAll(cfg.client_secret);
        const body = try body_buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(body);

        // Parse token URL to get host/port/path
        var token_host: []const u8 = "localhost";
        var token_port: u16 = 443;
        var token_path: []const u8 = "/oauth/token";
        var rest = cfg.token_url;
        if (mem.startsWith(u8, rest, "https://")) {
            rest = rest["https://".len..];
        } else if (mem.startsWith(u8, rest, "http://")) {
            rest = rest["http://".len..];
            token_port = 80;
        }
        if (mem.indexOf(u8, rest, "/")) |slash| {
            token_path = rest[slash..];
            rest = rest[0..slash];
        }
        if (mem.indexOf(u8, rest, ":")) |colon| {
            token_host = rest[0..colon];
            token_port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch token_port;
        } else {
            token_host = rest;
        }

        // Connect and send request
        const addr = std.net.Address.parseIp4(token_host, token_port) catch {
            if (mem.eql(u8, token_host, "localhost")) {
                return error.UnableToResolve;
            }
            return error.UnableToResolve;
        };

        const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        defer std.posix.close(sock);
        try std.posix.connect(sock, &addr.any, addr.getOsSockLen());

        var req: std.ArrayList(u8) = .{};
        defer req.deinit(self.allocator);
        const rw = req.writer(self.allocator);
        try rw.print("POST {s} HTTP/1.1\r\n", .{token_path});
        try rw.print("Host: {s}\r\n", .{token_host});
        try rw.writeAll("Content-Type: application/x-www-form-urlencoded\r\n");
        try rw.print("Content-Length: {d}\r\n", .{body.len});
        try rw.writeAll("Connection: close\r\n\r\n");
        try rw.writeAll(body);
        _ = try std.posix.write(sock, req.items);

        // Read response
        var response: std.ArrayList(u8) = .{};
        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(sock, &read_buf) catch break;
            if (n == 0) break;
            try response.appendSlice(self.allocator, read_buf[0..n]);
        }

        // Parse JSON for access_token
        const resp_body = blk: {
            if (mem.indexOf(u8, response.items, "\r\n\r\n")) |sep| {
                break :blk response.items[sep + 4 ..];
            }
            break :blk response.items;
        };

        // Simple JSON extraction
        const token_val = extractStringValue(resp_body, "access_token") orelse return error.TokenParseError;
        const token_type = extractStringValue(resp_body, "token_type") orelse "Bearer";

        self.oauth_token = .{
            .access_token = token_val,
            .token_type = token_type,
            .expires_in = 3600, // default 1hr
            .acquired_at = std.time.timestamp(),
        };
        response.deinit(self.allocator);

        std.log.info("[hana] OAuth token acquired, expires in 3600s", .{});
    }

    // ========================================================================
    // Connection Pool
    // ========================================================================

    fn acquireConnection(self: *HanaClient) !std.posix.socket_t {
        const now = std.time.timestamp();

        // Look for idle connection in pool
        for (&self.pool) |*entry| {
            if (entry.*) |*e| {
                if (!e.in_use) {
                    if (now - e.last_used > POOL_IDLE_TIMEOUT_S) {
                        // Expired — close and replace
                        std.posix.close(e.sock);
                        entry.* = null;
                        continue;
                    }
                    e.in_use = true;
                    e.last_used = now;
                    return e.sock;
                }
            }
        }

        // No idle connection — create new one
        const address = std.net.Address.parseIp4(self.host, self.port) catch blk: {
            if (mem.eql(u8, self.host, "localhost")) {
                break :blk try std.net.Address.parseIp4("127.0.0.1", self.port);
            }
            return error.UnableToResolve;
        };

        const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        try std.posix.connect(sock, &address.any, address.getOsSockLen());

        // Try to store in pool
        for (&self.pool) |*entry| {
            if (entry.* == null) {
                entry.* = .{
                    .sock = sock,
                    .last_used = now,
                    .in_use = true,
                };
                return sock;
            }
        }

        // Pool full — return unpooled socket
        return sock;
    }

    fn releaseConnection(self: *HanaClient, sock: std.posix.socket_t) void {
        for (&self.pool) |*entry| {
            if (entry.*) |*e| {
                if (e.sock == sock) {
                    e.in_use = false;
                    e.last_used = std.time.timestamp();
                    return;
                }
            }
        }
        // Not in pool — close it
        std.posix.close(sock);
    }

    // ========================================================================
    // SQL Execution
    // ========================================================================

    /// Execute a SQL statement against HANA via HTTP.
    /// Uses OAuth if configured, otherwise Basic auth. Uses connection pooling.
    /// Returns the raw JSON response body.
    pub fn executeSQL(self: *HanaClient, sql: []const u8) ![]const u8 {
        // Build JSON request body: {"sql": "<statement>"}
        var body_buf: std.ArrayList(u8) = .{};
        var bw = body_buf.writer(self.allocator);
        try bw.writeAll("{\"sql\":\"");
        for (sql) |c| {
            switch (c) {
                '"' => try bw.writeAll("\\\""),
                '\\' => try bw.writeAll("\\\\"),
                '\n' => try bw.writeAll("\\n"),
                '\r' => try bw.writeAll("\\r"),
                '\t' => try bw.writeAll("\\t"),
                else => try bw.writeByte(c),
            }
        }
        try bw.writeAll("\"}");
        const req_body = try body_buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(req_body);

        // Get auth header (OAuth or Basic)
        var auth_header_buf: [2048]u8 = undefined;
        const auth_header = try self.getAuthHeader(&auth_header_buf);

        // Acquire pooled connection
        const sock = try self.acquireConnection();
        errdefer self.releaseConnection(sock);

        // Build HTTP request
        var req: std.ArrayList(u8) = .{};
        defer req.deinit(self.allocator);
        var rw = req.writer(self.allocator);

        try rw.writeAll("POST /sql HTTP/1.1\r\n");
        try rw.print("Host: {s}\r\n", .{self.host});
        try rw.writeAll("Content-Type: application/json\r\n");
        try rw.print("Authorization: {s}\r\n", .{auth_header});
        try rw.print("Content-Length: {d}\r\n", .{req_body.len});
        try rw.writeAll("Connection: keep-alive\r\n");
        try rw.writeAll("\r\n");
        try rw.writeAll(req_body);

        _ = try std.posix.write(sock, req.items);

        // Read full response
        var response: std.ArrayList(u8) = .{};
        var read_buf: [8192]u8 = undefined;
        while (true) {
            const n = std.posix.read(sock, &read_buf) catch break;
            if (n == 0) break;
            try response.appendSlice(self.allocator, read_buf[0..n]);
        }

        // Release connection back to pool
        self.releaseConnection(sock);

        // Strip HTTP headers
        const sep = mem.indexOf(u8, response.items, "\r\n\r\n") orelse 0;
        if (sep > 0) {
            const body_slice = response.items[sep + 4 ..];
            const owned = try self.allocator.dupe(u8, body_slice);
            response.deinit(self.allocator);
            return owned;
        }

        return response.toOwnedSlice(self.allocator);
    }

    // ========================================================================
    // Schema Discovery
    // ========================================================================

    /// Discover all tables and columns in a HANA schema.
    /// Populates the Database with TableSchema entries.
    pub fn discoverSchema(self: *HanaClient, schema_name: []const u8, db: *schema_mod.Database) !void {
        // Query tables
        const tables_sql = try std.fmt.allocPrint(self.allocator,
            \\SELECT TABLE_NAME, TABLE_TYPE, COMMENTS
            \\FROM SYS.TABLES
            \\WHERE SCHEMA_NAME = '{s}'
            \\  AND TABLE_TYPE IN ('ROW', 'COLUMN')
            \\ORDER BY TABLE_NAME
        , .{schema_name});
        defer self.allocator.free(tables_sql);

        const tables_json = try self.executeSQL(tables_sql);
        defer self.allocator.free(tables_json);

        // Parse table names from response
        var table_names: std.ArrayList([]const u8) = .{};
        defer table_names.deinit(self.allocator);
        try parseTableNames(self.allocator, tables_json, &table_names);

        // For each table, discover columns
        for (table_names.items) |table_name| {
            var table_schema = schema_mod.TableSchema{
                .name = table_name,
                .columns = .{},
                .foreign_keys = .{},
                .primary_key = &.{},
            };

            // Query columns
            const cols_sql = try std.fmt.allocPrint(self.allocator,
                \\SELECT COLUMN_NAME, DATA_TYPE_NAME, IS_NULLABLE, LENGTH, SCALE, COMMENTS
                \\FROM SYS.TABLE_COLUMNS
                \\WHERE SCHEMA_NAME = '{s}' AND TABLE_NAME = '{s}'
                \\ORDER BY POSITION
            , .{ schema_name, table_name });
            defer self.allocator.free(cols_sql);

            const cols_json = try self.executeSQL(cols_sql);
            defer self.allocator.free(cols_json);
            try parseColumns(self.allocator, cols_json, &table_schema);

            // Query primary keys
            const pk_sql = try std.fmt.allocPrint(self.allocator,
                \\SELECT COLUMN_NAME
                \\FROM SYS.CONSTRAINTS
                \\WHERE SCHEMA_NAME = '{s}' AND TABLE_NAME = '{s}'
                \\  AND IS_PRIMARY_KEY = 'TRUE'
                \\ORDER BY POSITION
            , .{ schema_name, table_name });
            defer self.allocator.free(pk_sql);

            const pk_json = try self.executeSQL(pk_sql);
            defer self.allocator.free(pk_json);
            try parsePrimaryKeys(self.allocator, pk_json, &table_schema);

            // Query foreign keys
            const fk_sql = try std.fmt.allocPrint(self.allocator,
                \\SELECT COLUMN_NAME, REFERENCED_SCHEMA_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
                \\FROM SYS.REFERENTIAL_CONSTRAINTS
                \\WHERE SCHEMA_NAME = '{s}' AND TABLE_NAME = '{s}'
            , .{ schema_name, table_name });
            defer self.allocator.free(fk_sql);

            const fk_json = try self.executeSQL(fk_sql);
            defer self.allocator.free(fk_json);
            try parseForeignKeys(self.allocator, fk_json, &table_schema);

            try db.addSchema(table_schema);
        }
    }

    /// Generate SQL to list all schemas visible to the user.
    pub fn listSchemasSql(_: *HanaClient) []const u8 {
        return "SELECT SCHEMA_NAME FROM SYS.SCHEMAS WHERE HAS_PRIVILEGES = 'TRUE' ORDER BY SCHEMA_NAME";
    }
};

// ============================================================================
// HANA JSON Response Parsers
// ============================================================================

fn parseTableNames(allocator: Allocator, json: []const u8, names: *std.ArrayList([]const u8)) !void {
    var pos: usize = 0;
    while (pos < json.len) {
        const key = "\"TABLE_NAME\"";
        const key_pos = mem.indexOfPos(u8, json, pos, key) orelse break;
        const val = extractStringAfter(json, key_pos + key.len) orelse {
            pos = key_pos + key.len;
            continue;
        };
        try names.append(allocator, val);
        pos = key_pos + key.len;
    }
}

fn parseColumns(allocator: Allocator, json: []const u8, table: *schema_mod.TableSchema) !void {
    var pos: usize = 0;
    while (pos < json.len) {
        const col_key = "\"COLUMN_NAME\"";
        const col_pos = mem.indexOfPos(u8, json, pos, col_key) orelse break;
        const col_name = extractStringAfter(json, col_pos + col_key.len) orelse {
            pos = col_pos + col_key.len;
            continue;
        };

        const type_key = "\"DATA_TYPE_NAME\"";
        const type_name = if (mem.indexOfPos(u8, json, col_pos, type_key)) |tp|
            extractStringAfter(json, tp + type_key.len) orelse "VARCHAR"
        else
            "VARCHAR";

        const null_key = "\"IS_NULLABLE\"";
        const nullable = if (mem.indexOfPos(u8, json, col_pos, null_key)) |np|
            if (extractStringAfter(json, np + null_key.len)) |v|
                mem.eql(u8, v, "TRUE")
            else
                true
        else
            true;

        try table.columns.append(allocator, .{
            .name = col_name,
            .col_type = hanaTypeToColumnType(type_name),
            .nullable = nullable,
        });

        pos = col_pos + col_key.len;
    }
}

fn parsePrimaryKeys(allocator: Allocator, json: []const u8, table: *schema_mod.TableSchema) !void {
    var pk_names: std.ArrayList([]const u8) = .{};
    var pos: usize = 0;
    while (pos < json.len) {
        const key = "\"COLUMN_NAME\"";
        const key_pos = mem.indexOfPos(u8, json, pos, key) orelse break;
        const val = extractStringAfter(json, key_pos + key.len) orelse {
            pos = key_pos + key.len;
            continue;
        };
        try pk_names.append(allocator, val);
        pos = key_pos + key.len;
    }
    if (pk_names.items.len > 0) {
        table.primary_key = try pk_names.toOwnedSlice(allocator);
    }
}

fn parseForeignKeys(allocator: Allocator, json: []const u8, table: *schema_mod.TableSchema) !void {
    var pos: usize = 0;
    while (pos < json.len) {
        const col_key = "\"COLUMN_NAME\"";
        const col_pos = mem.indexOfPos(u8, json, pos, col_key) orelse break;
        const col_name = extractStringAfter(json, col_pos + col_key.len) orelse {
            pos = col_pos + col_key.len;
            continue;
        };

        const ref_tbl_key = "\"REFERENCED_TABLE_NAME\"";
        const ref_table = if (mem.indexOfPos(u8, json, col_pos, ref_tbl_key)) |rp|
            extractStringAfter(json, rp + ref_tbl_key.len) orelse ""
        else
            "";

        const ref_col_key = "\"REFERENCED_COLUMN_NAME\"";
        const ref_col = if (mem.indexOfPos(u8, json, col_pos, ref_col_key)) |rp|
            extractStringAfter(json, rp + ref_col_key.len) orelse ""
        else
            "";

        if (ref_table.len > 0) {
            try table.foreign_keys.append(allocator, .{
                .column = col_name,
                .ref_table = ref_table,
                .ref_column = ref_col,
            });
        }

        pos = col_pos + col_key.len;
    }
}

fn hanaTypeToColumnType(hana_type: []const u8) schema_mod.ColumnType {
    if (mem.eql(u8, hana_type, "INTEGER") or mem.eql(u8, hana_type, "INT") or
        mem.eql(u8, hana_type, "BIGINT") or mem.eql(u8, hana_type, "SMALLINT") or
        mem.eql(u8, hana_type, "TINYINT"))
        return .integer;
    if (mem.eql(u8, hana_type, "DECIMAL") or mem.eql(u8, hana_type, "DOUBLE") or
        mem.eql(u8, hana_type, "REAL") or mem.eql(u8, hana_type, "FLOAT"))
        return .float;
    if (mem.eql(u8, hana_type, "BOOLEAN"))
        return .boolean;
    return .text;
}

fn extractStringAfter(json: []const u8, after: usize) ?[]const u8 {
    var p = after;
    while (p < json.len and (json[p] == ':' or json[p] == ' ' or json[p] == '\t' or json[p] == '\n' or json[p] == '\r')) : (p += 1) {}
    if (p >= json.len or json[p] != '"') return null;
    p += 1;
    const start = p;
    while (p < json.len) : (p += 1) {
        if (json[p] == '\\') {
            p += 1;
            continue;
        }
        if (json[p] == '"') return json[start..p];
    }
    return null;
}

/// Extract a JSON string value by key name from raw JSON text.
/// e.g. extractStringValue(json, "access_token") finds "access_token":"<value>"
fn extractStringValue(json: []const u8, key: []const u8) ?[]const u8 {
    // Build search pattern: "key"
    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;
    const key_pos = mem.indexOf(u8, json, search) orelse return null;
    return extractStringAfter(json, key_pos + search.len);
}

// ============================================================================
// Tests
// ============================================================================

test "hana type mapping" {
    try std.testing.expectEqual(schema_mod.ColumnType.integer, hanaTypeToColumnType("INTEGER"));
    try std.testing.expectEqual(schema_mod.ColumnType.float, hanaTypeToColumnType("DECIMAL"));
    try std.testing.expectEqual(schema_mod.ColumnType.text, hanaTypeToColumnType("NVARCHAR"));
    try std.testing.expectEqual(schema_mod.ColumnType.text, hanaTypeToColumnType("DATE"));
}

test "extract string after" {
    const json = "\"key\": \"value\"";
    const result = extractStringAfter(json, 5);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("value", result.?);
}

test "extract string value by key" {
    const json = "{\"access_token\":\"abc123\",\"token_type\":\"Bearer\"}";
    const token = extractStringValue(json, "access_token");
    try std.testing.expect(token != null);
    try std.testing.expectEqualStrings("abc123", token.?);

    const ttype = extractStringValue(json, "token_type");
    try std.testing.expect(ttype != null);
    try std.testing.expectEqualStrings("Bearer", ttype.?);

    const missing = extractStringValue(json, "nonexistent");
    try std.testing.expect(missing == null);
}

test "oauth config not configured by default" {
    const cfg = OAuthConfig{
        .client_id = "",
        .client_secret = "",
        .token_url = "",
    };
    try std.testing.expect(!cfg.isConfigured());
}

test "connection pool init" {
    const allocator = std.testing.allocator;
    var client = HanaClient.init(allocator, "localhost", 443, "user", "pass", true);
    defer client.deinit();
    // Pool should be empty
    for (client.pool) |entry| {
        try std.testing.expect(entry == null);
    }
}

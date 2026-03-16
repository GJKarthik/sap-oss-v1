//! SAP HANA SQL-over-HTTP Client for Schema Discovery
//!
//! Queries SYS.TABLES, SYS.TABLE_COLUMNS, SYS.CONSTRAINTS, SYS.REFERENTIAL_CONSTRAINTS
//! to discover table schemas, columns, PKs, and FKs. Used to provide schema context
//! for PAL SQL CALL generation.
//!
//! Features (ported from search-svc):
//!   - OAuth 2.0 token acquisition and refresh
//!   - std.http.Client transport with native TLS
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
        };
    }

    pub fn deinit(self: *HanaClient) void {
        self.clearOAuthToken();
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

    fn clearOAuthToken(self: *HanaClient) void {
        if (self.oauth_token) |token| {
            self.allocator.free(token.access_token);
            self.allocator.free(token.token_type);
            self.oauth_token = null;
        }
    }

    fn setOAuthToken(self: *HanaClient, access_token: []const u8, token_type: []const u8, expires_in: i64) !void {
        const owned_access_token = try self.allocator.dupe(u8, access_token);
        errdefer self.allocator.free(owned_access_token);

        const owned_token_type = try self.allocator.dupe(u8, token_type);
        errdefer self.allocator.free(owned_token_type);

        self.clearOAuthToken();
        self.oauth_token = .{
            .access_token = owned_access_token,
            .token_type = owned_token_type,
            .expires_in = expires_in,
            .acquired_at = std.time.timestamp(),
        };
    }

    fn postRequest(
        self: *HanaClient,
        url: []const u8,
        content_type: []const u8,
        auth_header: ?[]const u8,
        body: []const u8,
    ) ![]const u8 {
        return self.postRequestWithStdHttp(url, content_type, auth_header, body) catch |err| switch (err) {
            error.TlsInitializationFailed => {
                if (!mem.startsWith(u8, url, "https://")) return error.ConnectionFailed;
                std.log.warn("[hana] std.http TLS init failed for {s}; falling back to curl", .{url});
                return self.postRequestWithCurl(url, content_type, auth_header, body);
            },
            else => {
                std.log.warn("[hana] HTTP POST failed for {s}: {}", .{ url, err });
                return error.ConnectionFailed;
            },
        };
    }

    fn postRequestWithStdHttp(
        self: *HanaClient,
        url: []const u8,
        content_type: []const u8,
        auth_header: ?[]const u8,
        body: []const u8,
    ) ![]const u8 {
        var client = std.http.Client{ .allocator = self.allocator };
        client.read_buffer_size = 32 * 1024;
        client.write_buffer_size = 32 * 1024;
        client.tls_buffer_size = 32 * 1024;
        defer client.deinit();

        var response_body: std.ArrayList(u8) = .{};
        defer response_body.deinit(self.allocator);
        var response_writer = response_body.writer(self.allocator);
        var response_writer_buf: [1024]u8 = undefined;
        var response_writer_adapter = response_writer.adaptToNewApi(&response_writer_buf);

        var extra_headers_buf: [2]std.http.Header = undefined;
        extra_headers_buf[0] = .{ .name = "Content-Type", .value = content_type };
        const extra_headers = if (auth_header) |value| blk: {
            extra_headers_buf[1] = .{ .name = "Authorization", .value = value };
            break :blk extra_headers_buf[0..2];
        } else extra_headers_buf[0..1];

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .extra_headers = extra_headers,
            .response_writer = &response_writer_adapter.new_interface,
        });

        try response_writer_adapter.new_interface.flush();

        const status_code: u16 = @intFromEnum(result.status);
        if (status_code < 200 or status_code >= 300) {
            std.log.warn("[hana] HTTP POST returned status {d} for {s}: {s}", .{ status_code, url, response_body.items });
        }

        return response_body.toOwnedSlice(self.allocator);
    }

    fn postRequestWithCurl(
        self: *HanaClient,
        url: []const u8,
        content_type: []const u8,
        auth_header: ?[]const u8,
        body: []const u8,
    ) ![]const u8 {
        const content_header = try std.fmt.allocPrint(self.allocator, "Content-Type: {s}", .{content_type});
        defer self.allocator.free(content_header);

        const auth_header_arg = if (auth_header) |value|
            try std.fmt.allocPrint(self.allocator, "Authorization: {s}", .{value})
        else
            null;
        defer if (auth_header_arg) |value| self.allocator.free(value);

        var argv_buf: [12][]const u8 = undefined;
        var argc: usize = 0;
        argv_buf[argc] = "curl";
        argc += 1;
        argv_buf[argc] = "--silent";
        argc += 1;
        argv_buf[argc] = "--show-error";
        argc += 1;
        argv_buf[argc] = "--request";
        argc += 1;
        argv_buf[argc] = "POST";
        argc += 1;
        argv_buf[argc] = "--header";
        argc += 1;
        argv_buf[argc] = content_header;
        argc += 1;
        if (auth_header_arg) |value| {
            argv_buf[argc] = "--header";
            argc += 1;
            argv_buf[argc] = value;
            argc += 1;
        }
        argv_buf[argc] = "--data-binary";
        argc += 1;
        argv_buf[argc] = "@-";
        argc += 1;
        argv_buf[argc] = url;
        argc += 1;

        var child = std.process.Child.init(argv_buf[0..argc], self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();
        errdefer _ = child.kill() catch {};

        const stdin = child.stdin orelse return error.ConnectionFailed;
        try stdin.writeAll(body);
        stdin.close();
        child.stdin = null;

        var stdout: std.ArrayList(u8) = .{};
        defer stdout.deinit(self.allocator);
        var stderr: std.ArrayList(u8) = .{};
        defer stderr.deinit(self.allocator);
        try child.collectOutput(self.allocator, &stdout, &stderr, 8 * 1024 * 1024);

        const term = try child.wait();
        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    std.log.warn("[hana] curl POST failed for {s} (exit {d}): {s}", .{ url, code, stderr.items });
                    return error.ConnectionFailed;
                }
            },
            else => {
                std.log.warn("[hana] curl POST terminated abnormally for {s}: {s}", .{ url, stderr.items });
                return error.ConnectionFailed;
            },
        }

        return stdout.toOwnedSlice(self.allocator);
    }

    fn buildSqlUrl(self: *HanaClient) ![]const u8 {
        const scheme = if (self.use_ssl) "https" else "http";
        return std.fmt.allocPrint(self.allocator, "{s}://{s}:{d}/sql", .{ scheme, self.host, self.port });
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

        const response = try self.postRequest(
            cfg.token_url,
            "application/x-www-form-urlencoded",
            null,
            body,
        );
        defer self.allocator.free(response);

        // Parse JSON for access_token
        // Simple JSON extraction
        const token_val = extractStringValue(response, "access_token") orelse return error.TokenParseError;
        const token_type = extractStringValue(response, "token_type") orelse "Bearer";

        try self.setOAuthToken(token_val, token_type, 3600);

        std.log.info("[hana] OAuth token acquired, expires in 3600s", .{});
    }

    // ========================================================================
    // SQL Execution
    // ========================================================================

    /// Execute a SQL statement against HANA via HTTP.
    /// Uses OAuth if configured, otherwise Basic auth.
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

        const url = try self.buildSqlUrl();
        defer self.allocator.free(url);

        return self.postRequest(url, "application/json", auth_header, req_body);
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

test "hana client init preserves TLS flag" {
    const allocator = std.testing.allocator;
    var client = HanaClient.init(allocator, "localhost", 443, "user", "pass", true);
    defer client.deinit();
    try std.testing.expect(client.use_ssl);
    try std.testing.expect(client.oauth_token == null);
}

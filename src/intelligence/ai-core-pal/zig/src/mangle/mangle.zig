const std = @import("std");
const openai = @import("../openai/openai_compliant.zig");

// ============================================================================
// Mangle Engine — .mg rule loader and intent router
// ============================================================================

pub const Fact = struct {
    predicate: []const u8,
    args: []const []const u8,
};

pub const Rule = struct {
    head_predicate: []const u8,
    head_args: []const []const u8,
    body: []const u8,
};

pub const Intent = enum {
    pal_catalog,
    pal_execute,
    pal_spec,
    pal_sql,
    pal_search,
    schema_explore,
    describe_table,
    hybrid_search,
    es_translate,
    pal_optimize,
    graph_publish,
    graph_query,
    odata_fetch,
    unknown,
};

pub const ApiRequest = struct {
    method: []const u8,
    url: []const u8,
    body: []const u8,
    headers: std.StringHashMap([]const u8),
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    facts: std.ArrayList(Fact),
    rules: std.ArrayList(Rule),
    intent_patterns: std.StringHashMap(Intent),

    pub fn init(allocator: std.mem.Allocator) Engine {
        return .{
            .allocator = allocator,
            .facts = .{},
            .rules = .{},
            .intent_patterns = std.StringHashMap(Intent).init(allocator),
        };
    }

    // ------------------------------------------------------------------
    // Bidirectional OpenAI Communication Logic
    // ------------------------------------------------------------------

    /// Query Mangle for A2A request flows and return a list of API calls to make
    pub fn queryA2AFlows(self: *Engine) !std.array_list.Managed(ApiRequest) {
        var flows = std.array_list.Managed(ApiRequest).init(self.allocator);
        
        // Match: api_call(Method, URL, Body)
        for (self.facts.items) |fact| {
            if (std.mem.eql(u8, fact.predicate, "api_call") and fact.args.len >= 3) {
                try flows.append(.{
                    .method = try self.allocator.dupe(u8, fact.args[0]),
                    .url = try self.allocator.dupe(u8, fact.args[1]),
                    .body = try self.allocator.dupe(u8, fact.args[2]),
                    .headers = std.StringHashMap([]const u8).init(self.allocator),
                });
            }
        }
        return flows;
    }

    /// Execute any api_request facts defined in Mangle rules
    pub fn executeApiFlows(self: *Engine) !void {
        const flows = try self.queryA2AFlows();
        defer flows.deinit();

        for (flows.items) |req| {
            std.log.info("Mangle A2A Flow: {s} {s}", .{ req.method, req.url });
            
            // Execute request (simplified)
            const result = try self.performRequest(req.method, req.url, req.body);
            
            // Re-inject result as a new fact for further reasoning
            try self.facts.append(self.allocator, .{
                .predicate = try self.allocator.dupe(u8, "api_response"),
                .args = &[_][]const u8{ try self.allocator.dupe(u8, req.url), result },
            });
        }
    }

    fn performRequest(self: *Engine, method: []const u8, url: []const u8, body: []const u8) ![]const u8 {
        _ = method;
        _ = url;
        _ = body;
        // In real implementation, this uses std.http.Client
        return try self.allocator.dupe(u8, "{\"status\":\"success\"}");
    }

    /// Formulate an OpenAI-compliant request based on Mangle state
    pub fn buildOpenAiRequest(self: *Engine, model: []const u8, user_msg: []const u8) ![]const u8 {
        const req = openai.ChatCompletionRequest{
            .model = model,
            .messages = &[_]openai.Message{
                .{ .role = "user", .content = user_msg },
            },
        };
        return std.json.Stringify.valueAlloc(self.allocator, req, .{});
    }

    pub fn deinit(self: *Engine) void {
        self.facts.deinit(self.allocator);
        self.rules.deinit(self.allocator);
        self.intent_patterns.deinit();
    }

    pub fn loadFile(self: *Engine, path: []const u8) !void {
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            std.log.warn("Mangle: could not open {s}: {}", .{ path, err });
            return;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 2 * 1024 * 1024);
        defer self.allocator.free(content);

        // SHA-256 integrity check: look for companion <path>.sha256 sidecar.
        // If the sidecar exists the hash MUST match; a missing sidecar is a
        // warning only so existing deployments without sidecars keep working.
        try verifyFileIntegrity(self.allocator, path, content);

        try self.parseContent(content);
    }

    pub fn loadDir(self: *Engine, dir_path: []const u8) !void {
        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| {
            std.log.warn("Mangle: could not open dir {s}: {}", .{ dir_path, err });
            return;
        };
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .directory) {
                const sub_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
                defer self.allocator.free(sub_path);
                try self.loadDir(sub_path);
            } else if (std.mem.endsWith(u8, entry.name, ".mg")) {
                const file_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
                defer self.allocator.free(file_path);
                try self.loadFile(file_path);
            }
        }
    }

    fn parseContent(self: *Engine, content: []const u8) !void {
        var lines = std.mem.splitSequence(u8, content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            // Skip comments (// or #)
            if (trimmed[0] == '#') continue;
            if (trimmed.len >= 2 and trimmed[0] == '/' and trimmed[1] == '/') continue;

            // Parse facts: predicate("arg1", "arg2", ...).
            if (std.mem.indexOf(u8, trimmed, ":-")) |_| {
                // This is a rule — store the raw rule text
                try self.rules.append(self.allocator, .{
                    .head_predicate = try self.allocator.dupe(u8, trimmed),
                    .head_args = &.{},
                    .body = "",
                });
            } else if (trimmed[trimmed.len - 1] == '.') {
                // This is a fact
                if (std.mem.indexOf(u8, trimmed, "(")) |paren_idx| {
                    const predicate = try self.allocator.dupe(u8, trimmed[0..paren_idx]);
                    var args: std.ArrayList([]const u8) = .{};

                    // Extract quoted arguments
                    var i: usize = paren_idx;
                    while (i < trimmed.len) : (i += 1) {
                        if (trimmed[i] == '"') {
                            i += 1;
                            const start = i;
                            while (i < trimmed.len and trimmed[i] != '"') : (i += 1) {}
                            try args.append(self.allocator, try self.allocator.dupe(u8, trimmed[start..i]));
                        }
                    }

                    try self.facts.append(self.allocator, .{
                        .predicate = predicate,
                        .args = try args.toOwnedSlice(self.allocator),
                    });

                    // Auto-register intent patterns
                    if (std.mem.eql(u8, predicate, "intent_pattern") and args.items.len >= 2) {
                        // Already consumed by toOwnedSlice, use fact args
                        const fact = &self.facts.items[self.facts.items.len - 1];
                        if (fact.args.len >= 2) {
                            const intent = resolveIntent(fact.args[0]);
                            try self.intent_patterns.put(fact.args[1], intent);
                        }
                    }
                }
            }
        }
    }

    pub fn loadDefaultIntents(self: *Engine) !void {
        const patterns = [_]struct { []const u8, Intent }{
            .{ "list algorithm", .pal_catalog },
            .{ "available algorithm", .pal_catalog },
            .{ "pal catalog", .pal_catalog },
            .{ "which pal", .pal_catalog },
            .{ "what algorithm", .pal_catalog },
            .{ "list categories", .pal_catalog },
            .{ "show categories", .pal_catalog },
            .{ "run pal", .pal_execute },
            .{ "execute pal", .pal_execute },
            .{ "execute", .pal_execute },
            .{ "call _sys_afl", .pal_execute },
            .{ "generate sql", .pal_execute },
            .{ "pal execute", .pal_execute },
            .{ "create sql", .pal_execute },
            .{ "hana call", .pal_execute },
            .{ "spec for", .pal_spec },
            .{ "specification", .pal_spec },
            .{ "odps spec", .pal_spec },
            .{ "yaml spec", .pal_spec },
            .{ "algorithm detail", .pal_spec },
            .{ "sql template", .pal_sql },
            .{ "sql for", .pal_sql },
            .{ "sqlscript", .pal_sql },
            .{ "show sql", .pal_sql },
            .{ "search", .pal_search },
            .{ "find algorithm", .pal_search },
            .{ "kmeans", .pal_search },
            .{ "arima", .pal_search },
            .{ "clustering", .pal_search },
            .{ "classification", .pal_search },
            .{ "regression", .pal_search },
            .{ "forecasting", .pal_search },
            .{ "list tables", .schema_explore },
            .{ "show tables", .schema_explore },
            .{ "show schema", .schema_explore },
            .{ "what tables", .schema_explore },
            .{ "database schema", .schema_explore },
            .{ "table schema", .schema_explore },
            .{ "available tables", .schema_explore },
            .{ "describe table", .describe_table },
            .{ "columns of", .describe_table },
            .{ "columns in", .describe_table },
            .{ "columns for", .describe_table },
            .{ "table columns", .describe_table },
            .{ "table structure", .describe_table },
            .{ "describe ", .describe_table },
            .{ "hybrid search", .hybrid_search },
            .{ "semantic search", .hybrid_search },
            .{ "vector search", .hybrid_search },
            .{ "search documents", .hybrid_search },
            .{ "find documents", .hybrid_search },
            .{ "rag search", .hybrid_search },
            .{ "translate to hana", .es_translate },
            .{ "es to hana", .es_translate },
            .{ "elasticsearch to hana", .es_translate },
            .{ "convert query", .es_translate },
            .{ "translate query", .es_translate },
            .{ "optimize pal", .pal_optimize },
            .{ "pal optimization", .pal_optimize },
            .{ "tune parameters", .pal_optimize },
            .{ "recommend algorithm", .pal_optimize },
            .{ "best algorithm", .pal_optimize },
            .{ "which algorithm for", .pal_optimize },
            .{ "publish to graph", .graph_publish },
            .{ "store in graph", .graph_publish },
            .{ "save to graph", .graph_publish },
            .{ "create graph node", .graph_publish },
            .{ "publish schema", .graph_publish },
            .{ "publish results", .graph_publish },
            .{ "graph query", .graph_query },
            .{ "query graph", .graph_query },
            .{ "show lineage", .graph_query },
            .{ "show dependencies", .graph_query },
            .{ "data product", .graph_query },
            .{ "impact analysis", .graph_query },
            .{ "what depends on", .graph_query },
            .{ "who uses", .graph_query },
            .{ "trace lineage", .graph_query },
            .{ "fetch odata", .odata_fetch },
            .{ "odata service", .odata_fetch },
            .{ "sap odata", .odata_fetch },
            .{ "pull data from", .odata_fetch },
            .{ "import odata", .odata_fetch },
        };
        for (patterns) |p| {
            try self.intent_patterns.put(p[0], p[1]);
        }
    }

    pub fn detectIntent(self: *const Engine, message: []const u8) Intent {
        // Lowercase comparison
        var lower_buf: [4096]u8 = undefined;
        const len = @min(message.len, lower_buf.len);
        for (0..len) |i| {
            lower_buf[i] = if (message[i] >= 'A' and message[i] <= 'Z') message[i] + 32 else message[i];
        }
        const lower = lower_buf[0..len];

        // Priority-based matching: longest matching pattern wins.
        // This ensures "execute pal" beats "search" when both could match.
        var best_intent: Intent = .unknown;
        var best_len: usize = 0;

        var it = self.intent_patterns.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.*.len > best_len) {
                if (std.mem.indexOf(u8, lower, entry.key_ptr.*) != null) {
                    best_intent = entry.value_ptr.*;
                    best_len = entry.key_ptr.*.len;
                }
            }
        }
        return best_intent;
    }

    /// Query a 2-arg fact by predicate and first argument, returning the second argument.
    /// e.g. queryFactValue("hana_credential", "host") returns the host value.
    pub fn queryFactValue(self: *const Engine, predicate: []const u8, key: []const u8) ?[]const u8 {
        for (self.facts.items) |fact| {
            if (std.mem.eql(u8, fact.predicate, predicate) and fact.args.len >= 2) {
                if (std.mem.eql(u8, fact.args[0], key)) {
                    return fact.args[1];
                }
            }
        }
        return null;
    }

    pub fn factCount(self: *const Engine) usize {
        return self.facts.items.len;
    }

    pub fn ruleCount(self: *const Engine) usize {
        return self.rules.items.len;
    }
};

// ============================================================================
// SHA-256 integrity helpers
// ============================================================================

/// Compute the lowercase hex SHA-256 of data into a 64-byte buffer.
fn sha256Hex(out: *[64]u8, data: []const u8) void {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    const hex = "0123456789abcdef";
    for (hash, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
}

/// Check <path>.sha256 sidecar against the SHA-256 of content.
/// Returns error.IntegrityCheckFailed if sidecar exists and hash mismatches.
/// Returns without error if the sidecar is absent (soft enforcement).
fn verifyFileIntegrity(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    // Build sidecar path: <path>.sha256
    const sidecar_path = try std.fmt.allocPrint(allocator, "{s}.sha256", .{path});
    defer allocator.free(sidecar_path);

    const sidecar_file = std.fs.openFileAbsolute(sidecar_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.debug("Mangle: no integrity sidecar for {s} — skipping check", .{path});
            return;
        },
        else => return err,
    };
    defer sidecar_file.close();

    // Read expected hash (up to 64 hex chars + optional whitespace)
    var expected_buf: [128]u8 = undefined;
    const n = try sidecar_file.readAll(&expected_buf);
    const expected = std.mem.trim(u8, expected_buf[0..n], " \t\r\n");

    if (expected.len < 64) {
        std.log.warn("Mangle: sidecar {s} is malformed (too short)", .{sidecar_path});
        return error.IntegrityCheckFailed;
    }

    var actual_hex: [64]u8 = undefined;
    sha256Hex(&actual_hex, content);

    if (!std.mem.eql(u8, expected[0..64], &actual_hex)) {
        std.log.err("Mangle: integrity check FAILED for {s}", .{path});
        std.log.err("  expected: {s}", .{expected[0..64]});
        std.log.err("  actual:   {s}", .{actual_hex});
        return error.IntegrityCheckFailed;
    }

    std.log.info("Mangle: integrity verified for {s}", .{path});
}

fn resolveIntent(name: []const u8) Intent {
    if (std.mem.indexOf(u8, name, "catalog") != null or std.mem.indexOf(u8, name, "list") != null) return .pal_catalog;
    if (std.mem.indexOf(u8, name, "execute") != null or std.mem.indexOf(u8, name, "run") != null) return .pal_execute;
    if (std.mem.indexOf(u8, name, "spec") != null) return .pal_spec;
    if (std.mem.indexOf(u8, name, "sql") != null) return .pal_sql;
    if (std.mem.indexOf(u8, name, "hybrid") != null or std.mem.indexOf(u8, name, "semantic") != null or std.mem.indexOf(u8, name, "vector_search") != null) return .hybrid_search;
    if (std.mem.indexOf(u8, name, "es_to_hana") != null or std.mem.indexOf(u8, name, "translate") != null) return .es_translate;
    if (std.mem.indexOf(u8, name, "optimize") != null or std.mem.indexOf(u8, name, "recommend") != null) return .pal_optimize;
    if (std.mem.indexOf(u8, name, "graph_publish") != null or std.mem.indexOf(u8, name, "publish") != null) return .graph_publish;
    if (std.mem.indexOf(u8, name, "graph_query") != null or std.mem.indexOf(u8, name, "lineage") != null or std.mem.indexOf(u8, name, "impact") != null) return .graph_query;
    if (std.mem.indexOf(u8, name, "odata") != null or std.mem.indexOf(u8, name, "fetch_data") != null) return .odata_fetch;
    if (std.mem.indexOf(u8, name, "search") != null) return .pal_search;
    if (std.mem.indexOf(u8, name, "schema") != null or std.mem.indexOf(u8, name, "table") != null) return .schema_explore;
    if (std.mem.indexOf(u8, name, "describe") != null or std.mem.indexOf(u8, name, "column") != null) return .describe_table;
    return .unknown;
}

// ============================================================================
// Tests
// ============================================================================

test "sha256 hex known value" {
    var hex: [64]u8 = undefined;
    sha256Hex(&hex, "hello");
    try std.testing.expectEqualStrings(
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        &hex,
    );
}

test "integrity check passes when sidecar matches" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const content = "intent_pattern(\"pal_catalog\", \"list algorithms\").";

    // Write .mg file
    const mg_file = try tmp.dir.createFile("rules.mg", .{});
    try mg_file.writeAll(content);
    mg_file.close();

    // Write matching .sha256 sidecar
    var expected_hex: [64]u8 = undefined;
    sha256Hex(&expected_hex, content);
    const sidecar = try tmp.dir.createFile("rules.mg.sha256", .{});
    try sidecar.writeAll(&expected_hex);
    sidecar.close();

    // Build absolute paths
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const mg_path = try std.fmt.bufPrint(&full_buf, "{s}/rules.mg", .{dir_path});

    try verifyFileIntegrity(allocator, mg_path, content);
}

test "integrity check fails when sidecar mismatches" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const content = "intent_pattern(\"pal_catalog\", \"list algorithms\").";

    const mg_file = try tmp.dir.createFile("bad.mg", .{});
    try mg_file.writeAll(content);
    mg_file.close();

    // Write deliberately wrong hash
    const sidecar = try tmp.dir.createFile("bad.mg.sha256", .{});
    try sidecar.writeAll("0000000000000000000000000000000000000000000000000000000000000000");
    sidecar.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const mg_path = try std.fmt.bufPrint(&full_buf, "{s}/bad.mg", .{dir_path});

    const result = verifyFileIntegrity(allocator, mg_path, content);
    try std.testing.expectError(error.IntegrityCheckFailed, result);
}

test "integrity check skips when no sidecar" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const content = "intent_pattern(\"pal_catalog\", \"list algorithms\").";

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const mg_path = try std.fmt.bufPrint(&full_buf, "{s}/nosidecar.mg", .{dir_path});

    // No sidecar written — should succeed silently
    try verifyFileIntegrity(allocator, mg_path, content);
}

const std = @import("std");
const openai = @import("openai_compliant.zig");

// ============================================================================
// Mangle Engine — .mg rule loader and A2A intent router
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

pub const ApiRequest = struct {
    method: []const u8,
    url: []const u8,
    body: []const u8,
    headers: std.StringHashMap([]const u8),
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
    news_search,
    data_profile,
    general_chat,
    unknown,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    facts: std.ArrayList(Fact),
    rules: std.ArrayList(Rule),
    intent_patterns: std.StringHashMap(Intent),

    pub fn init(allocator: std.mem.Allocator) !Engine {
        var engine = Engine{
            .allocator = allocator,
            .facts = .{},
            .rules = .{},
            .intent_patterns = std.StringHashMap(Intent).init(allocator),
        };
        try engine.loadDefaultIntents();
        return engine;
    }

    pub fn deinit(self: *Engine) void {
        self.facts.deinit();
        self.rules.deinit();
        self.intent_patterns.deinit();
    }

    // ------------------------------------------------------------------
    // Bidirectional OpenAI Communication (A2A)
    // ------------------------------------------------------------------

    pub fn queryA2AFlows(self: *Engine) !std.ArrayList(ApiRequest) {
        var flows = std.ArrayList(ApiRequest){};
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

    pub fn executeApiFlows(self: *Engine) !void {
        const flows = try self.queryA2AFlows();
        defer {
            for (flows.items) |req| {
                self.allocator.free(req.method);
                self.allocator.free(req.url);
                self.allocator.free(req.body);
            }
            flows.deinit();
        }

        for (flows.items) |req| {
            std.log.info("Mangle A2A Flow: {s} {s}", .{ req.method, req.url });
            const result = try self.performRequest(req.method, req.url, req.body);
            
            try self.facts.append(.{
                .predicate = try self.allocator.dupe(u8, "api_response"),
                .args = try self.allocator.dupe([]const u8, &[_][]const u8{ try self.allocator.dupe(u8, req.url), result }),
            });
        }
    }

    fn performRequest(self: *Engine, method: []const u8, url: []const u8, body: []const u8) ![]const u8 {
        _ = method; _ = url; _ = body;
        return try self.allocator.dupe(u8, "{\"status\":\"success\",\"message\":\"A2A auto-response\"}");
    }

    // ------------------------------------------------------------------
    // Content Parsing & Intent Detection
    // ------------------------------------------------------------------

    pub fn detectIntent(self: *const Engine, message: []const u8) Intent {
        var lower_buf: [4096]u8 = undefined;
        const len = @min(message.len, lower_buf.len);
        for (0..len) |i| lower_buf[i] = if (message[i] >= 'A' and message[i] <= 'Z') message[i] + 32 else message[i];
        const lower = lower_buf[0..len];

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

    pub fn loadFile(self: *Engine, path: []const u8) !void {
        const content = std.fs.cwd().readFileAlloc(self.allocator, path, 2 * 1024 * 1024) catch return;
        defer self.allocator.free(content);
        try self.parseContent(content);
    }

    fn parseContent(self: *Engine, content: []const u8) !void {
        var lines = std.mem.splitSequence(u8, content, "
");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " 	");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            if (std.mem.indexOf(u8, trimmed, ":-")) |_| {
                try self.rules.append(.{ .head_predicate = try self.allocator.dupe(u8, trimmed), .head_args = &.{}, .body = "" });
            } else if (trimmed[trimmed.len - 1] == '.') {
                if (std.mem.indexOf(u8, trimmed, "(")) |paren_idx| {
                    const predicate = try self.allocator.dupe(u8, trimmed[0..paren_idx]);
                    var args = std.ArrayList([]const u8){};
                    var i: usize = paren_idx;
                    while (i < trimmed.len) : (i += 1) {
                        if (trimmed[i] == '"') {
                            i += 1;
                            const start = i;
                            while (i < trimmed.len and trimmed[i] != '"') : (i += 1) {}
                            try args.append(try self.allocator.dupe(u8, trimmed[start..i]));
                        }
                    }
                    try self.facts.append(.{ .predicate = predicate, .args = try args.toOwnedSlice() });
                }
            }
        }
    }

    fn loadDefaultIntents(self: *Engine) !void {
        const patterns = [_]struct { []const u8, Intent }{
            .{ "list algorithm", .pal_catalog },
            .{ "run pal", .pal_execute },
            .{ "search news", .news_search },
            .{ "profile table", .data_profile },
            .{ "query graph", .graph_query },
        };
        for (patterns) |p| try self.intent_patterns.put(p[0], p[1]);
    }
};

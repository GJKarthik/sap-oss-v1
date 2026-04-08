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
            .facts = std.ArrayList(Fact).init(allocator),
            .rules = std.ArrayList(Rule).init(allocator),
            .intent_patterns = std.StringHashMap(Intent).init(allocator),
        };
    }

    pub fn deinit(self: *Engine) void {
        for (self.facts.items) |f| {
            self.allocator.free(f.predicate);
            for (f.args) |a| self.allocator.free(a);
            self.allocator.free(f.args);
        }
        self.facts.deinit();
        for (self.rules.items) |r| {
            self.allocator.free(r.head_predicate);
            for (r.head_args) |a| self.allocator.free(a);
            self.allocator.free(r.head_args);
            self.allocator.free(r.body);
        }
        self.rules.deinit();
        self.intent_patterns.deinit();
    }

    pub fn loadRules(_: *Engine, _: []const u8) !void {
        // Placeholder for production
    }

    pub fn loadDefaultIntents(_: *Engine) !void {
        // Placeholder for production
    }

    pub fn loadDir(_: *Engine, _: []const u8) !void {
        // Placeholder for production
    }

    pub fn loadFile(_: *Engine, _: []const u8) !void {
        // Placeholder for production
    }

    pub fn factCount(self: *const Engine) usize {
        return self.facts.items.len;
    }

    pub fn ruleCount(self: *const Engine) usize {
        return self.rules.items.len;
    }

    pub fn queryFactValue(self: *const Engine, predicate: []const u8, key: []const u8) ?[]const u8 {
        for (self.facts.items) |f| {
            if (std.mem.eql(u8, f.predicate, predicate) and f.args.len >= 2) {
                if (std.mem.eql(u8, f.args[0], key)) return f.args[1];
            }
        }
        return null;
    }

    pub fn detectIntent(_: *Engine, _: []const u8) Intent {
        return .unknown;
    }

    pub fn executeApiFlows(_: *Engine) !void {
        // Placeholder for production
    }
};

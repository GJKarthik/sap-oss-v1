//! Mangle Prompt Engine
//!
//! Enhances prompts using Datalog-style rules for improved LLM interactions.
//! Mangle rules can inject context, modify instructions, or augment queries.

const std = @import("std");
const json = std.json;
const mem = std.mem;
const Allocator = mem.Allocator;

// ============================================================================
// Mangle Engine
// ============================================================================

pub const Engine = struct {
    allocator: Allocator,
    rules: std.StringHashMap(Rule),
    context_injections: std.ArrayListUnmanaged([]const u8),
    rules_path: ?[]const u8,
    /// Runtime facts asserted dynamically at request time (key -> integer value).
    /// Used for cost-routing: e.g. gpu_queue_depth["/tensorrt"] = 37
    runtime_facts: std.StringHashMap(i64),
    /// Routing thresholds (can be overridden by rules file)
    trt_queue_overflow_threshold: i64, // fallback to /gguf when TRT queue >= this
    trt_queue_high_watermark: i64, // warn/log when queue >= this
    /// Whether TensorRT engine is actually available (false = always route to /gguf)
    tensorrt_available: bool = false,

    pub fn init(allocator: Allocator, rules_path: ?[]const u8) !Engine {
        var engine = Engine{
            .allocator = allocator,
            .rules = std.StringHashMap(Rule).init(allocator),
            .context_injections = std.ArrayListUnmanaged([]const u8){},
            .rules_path = if (rules_path) |p| try allocator.dupe(u8, p) else null,
            .runtime_facts = std.StringHashMap(i64).init(allocator),
            .trt_queue_overflow_threshold = 56, // 87.5% of max_inflight=64
            .trt_queue_high_watermark = 48, // 75% of max_inflight=64
            .tensorrt_available = false,
        };

        if (rules_path) |path| {
            engine.loadRulesFromFile(path) catch |err| {
                std.log.warn("Failed to load custom rules from {s}: {}. Falling back to default rules.", .{ path, err });
                try engine.loadDefaultRules();
            };
        } else {
            try engine.loadDefaultRules();
        }

        return engine;
    }

    pub fn deinit(self: *Engine) void {
        var iter = self.rules.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.pattern);
            self.allocator.free(entry.value_ptr.content);
        }
        self.rules.deinit();
        self.context_injections.deinit(self.allocator);
        if (self.rules_path) |p| self.allocator.free(p);
        // Free runtime fact keys (values are i64, no allocation needed)
        var rf_iter = self.runtime_facts.keyIterator();
        while (rf_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.runtime_facts.deinit();
    }

    /// Load default prompt enhancement rules
    fn loadDefaultRules(self: *Engine) !void {
        // Rule: Add system context for code-related queries
        try self.addRule("code_context", Rule{
            .pattern = "code",
            .action = .inject_system,
            .content = "You are a helpful coding assistant. Provide clear, well-documented code examples.",
        });

        // Rule: Add system context for analysis queries
        try self.addRule("analysis_context", Rule{
            .pattern = "analyze",
            .action = .inject_system,
            .content = "You are an expert analyst. Provide thorough, structured analysis with clear reasoning.",
        });

        // Rule: Enhance log-related queries
        try self.addRule("log_context", Rule{
            .pattern = "log",
            .action = .inject_system,
            .content = "You are a log analysis expert. Focus on identifying patterns, anomalies, and root causes.",
        });

        // Rule: Add JSON formatting instruction
        try self.addRule("json_format", Rule{
            .pattern = "json",
            .action = .append_instruction,
            .content = " Please format the response as valid JSON.",
        });

        // Rule: Add structured output for summarization
        try self.addRule("summarize", Rule{
            .pattern = "summarize",
            .action = .inject_system,
            .content = "Provide concise, well-structured summaries with key points highlighted.",
        });
    }

    pub fn addRule(self: *Engine, name: []const u8, rule: Rule) !void {
        const stored_name = try self.allocator.dupe(u8, name);
        const stored_pattern = try self.allocator.dupe(u8, rule.pattern);
        const stored_content = try self.allocator.dupe(u8, rule.content);
        try self.rules.put(stored_name, Rule{
            .pattern = stored_pattern,
            .action = rule.action,
            .content = stored_content,
            .temperature = rule.temperature,
        });
    }

    pub fn addContextInjection(self: *Engine, context: []const u8) !void {
        try self.context_injections.append(context);
    }

    // ========================================================================
    // Runtime Fact API — for dynamic cost-routing assertions
    // ========================================================================

    /// Assert a named integer fact at request time.
    /// If the fact already exists its value is updated in-place (no double-alloc).
    /// Typical usage: `engine.assertRuntimeFact("gpu_queue_depth:/tensorrt", queue_count)`
    pub fn assertRuntimeFact(self: *Engine, key: []const u8, value: i64) !void {
        const result = try self.runtime_facts.getOrPut(key);
        if (!result.found_existing) {
            result.key_ptr.* = try self.allocator.dupe(u8, key);
        }
        result.value_ptr.* = value;
    }

    /// Remove a runtime fact (no-op if key is not present).
    pub fn retractRuntimeFact(self: *Engine, key: []const u8) void {
        if (self.runtime_facts.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    /// Read a runtime fact value, or null if not asserted.
    pub fn getRuntimeFact(self: *const Engine, key: []const u8) ?i64 {
        return self.runtime_facts.get(key);
    }

    /// Load rules from a JSON file
    pub fn loadRulesFromFile(self: *Engine, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const content = try self.allocator.alloc(u8, stat.size);
        defer self.allocator.free(content);

        const bytes_read = try file.readAll(content);
        if (bytes_read != stat.size) return error.IncompleteRead;

        try self.reloadRulesFromJson(content);
    }

    /// Hot-reload rules from a JSON string
    pub fn reloadRulesFromJson(self: *Engine, json_str: []const u8) !void {
        const RuleJson = struct {
            name: []const u8,
            pattern: []const u8,
            action: []const u8,
            content: []const u8,
            temperature: ?f32 = null,
        };
        const Schema = struct {
            rules: []RuleJson,
        };

        const parsed = try json.parseFromSlice(Schema, self.allocator, json_str, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        // Clear existing rules safely
        var iter = self.rules.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.pattern);
            self.allocator.free(entry.value_ptr.content);
        }
        self.rules.clearRetainingCapacity();

        for (parsed.value.rules) |r| {
            const action = std.meta.stringToEnum(RuleAction, r.action) orelse continue;
            try self.rules.put(try self.allocator.dupe(u8, r.name), Rule{
                .pattern = try self.allocator.dupe(u8, r.pattern),
                .action = action,
                .content = try self.allocator.dupe(u8, r.content),
                .temperature = r.temperature,
            });
        }
        std.log.info("Mangle Engine hot-reloaded {d} rules successfully.", .{self.rules.count()});
    }

    /// Enhance a chat completion request body with Mangle rules
    pub fn enhancePrompt(self: *Engine, body: []const u8) ![]const u8 {
        // Try to parse as JSON
        const parsed = json.parseFromSlice(json.Value, self.allocator, body, .{}) catch {
            // Not valid JSON, return as-is
            return body;
        };
        defer parsed.deinit();

        const root = parsed.value;

        // Get messages array
        const messages = root.object.get("messages") orelse return body;
        if (messages != .array) return body;

        // Check if we need to apply any rules
        var should_inject_system = false;
        var system_content = std.ArrayListUnmanaged(u8){};
        var additional_instructions = std.ArrayListUnmanaged(u8){};

        // Analyze user messages for rule triggers
        for (messages.array.items) |msg| {
            const role = msg.object.get("role") orelse continue;
            const content = msg.object.get("content") orelse continue;

            if (!mem.eql(u8, role.string, "user")) continue;

            const user_content = content.string;
            const lower = std.ascii.allocLowerString(self.allocator, user_content) catch continue;
            defer self.allocator.free(lower);

            // Check each rule
            var rule_iter = self.rules.iterator();
            while (rule_iter.next()) |entry| {
                const rule = entry.value_ptr.*;
                if (mem.indexOf(u8, lower, rule.pattern) != null) {
                    switch (rule.action) {
                        .inject_system => {
                            should_inject_system = true;
                            try system_content.appendSlice(self.allocator, rule.content);
                            try system_content.append(self.allocator, ' ');
                        },
                        .append_instruction => {
                            try additional_instructions.appendSlice(self.allocator, rule.content);
                        },
                        .modify_temperature => {
                            // Would modify request parameters
                        },
                    }
                }
            }
        }

        // If no modifications needed, return original
        if (!should_inject_system and additional_instructions.items.len == 0) {
            system_content.deinit(self.allocator);
            additional_instructions.deinit(self.allocator);
            return body;
        }

        // Build enhanced request using buffer-based JSON building (Zig 0.15.x compatible)
        var result: std.ArrayListUnmanaged(u8) = .empty;
        defer {
            system_content.deinit(self.allocator);
            additional_instructions.deinit(self.allocator);
        }

        try result.append(self.allocator, '{');

        // Copy model
        if (root.object.get("model")) |model| {
            try result.appendSlice(self.allocator, "\"model\":\"");
            try result.appendSlice(self.allocator, model.string);
            try result.appendSlice(self.allocator, "\",");
        }

        // Build messages array
        try result.appendSlice(self.allocator, "\"messages\":[");

        // Inject system message if needed
        if (should_inject_system and system_content.items.len > 0) {
            try result.appendSlice(self.allocator, "{\"role\":\"system\",\"content\":\"");
            try appendJsonEscaped(&result, self.allocator, system_content.items);
            try result.appendSlice(self.allocator, "\"},");
        }

        // Copy original messages
        var msg_idx: usize = 0;
        for (messages.array.items) |msg| {
            const role_val = msg.object.get("role") orelse continue;
            const content_val = msg.object.get("content") orelse continue;

            if (msg_idx > 0 or (should_inject_system and system_content.items.len > 0)) {
                // Comma already added after system message or previous message
            }

            try result.appendSlice(self.allocator, "{\"role\":\"");
            try result.appendSlice(self.allocator, role_val.string);
            try result.appendSlice(self.allocator, "\",\"content\":\"");

            // For user messages, append instructions if any
            if (mem.eql(u8, role_val.string, "user")) {
                if (additional_instructions.items.len > 0) {
                    try appendJsonEscaped(&result, self.allocator, content_val.string);
                    try appendJsonEscaped(&result, self.allocator, additional_instructions.items);
                } else {
                    try appendJsonEscaped(&result, self.allocator, content_val.string);
                }
            } else {
                try appendJsonEscaped(&result, self.allocator, content_val.string);
            }

            try result.appendSlice(self.allocator, "\"}");

            msg_idx += 1;
            if (msg_idx < messages.array.items.len) {
                try result.append(self.allocator, ',');
            }
        }

        // Remove trailing comma from messages array
        if (msg_idx > 0 or (should_inject_system and system_content.items.len > 0)) {
            _ = result.pop();
        }

        try result.appendSlice(self.allocator, "],");

        // Copy other fields
        var iter = root.object.iterator();
        while (iter.next()) |entry| {
            if (mem.eql(u8, entry.key_ptr.*, "model") or mem.eql(u8, entry.key_ptr.*, "messages")) {
                continue;
            }

            try result.appendSlice(self.allocator, "\"");
            try result.appendSlice(self.allocator, entry.key_ptr.*);
            try result.appendSlice(self.allocator, "\":");

            // Serialize value
            switch (entry.value_ptr.*) {
                .integer => |i| {
                    var buf: [64]u8 = undefined;
                    const num_str = std.fmt.bufPrint(&buf, "{d}", .{i}) catch "0";
                    try result.appendSlice(self.allocator, num_str);
                },
                .float => |f| {
                    var buf: [64]u8 = undefined;
                    const num_str = std.fmt.bufPrint(&buf, "{d}", .{f}) catch "0.0";
                    try result.appendSlice(self.allocator, num_str);
                },
                .string => |s| {
                    try result.appendSlice(self.allocator, "\"");
                    try appendJsonEscaped(&result, self.allocator, s);
                    try result.appendSlice(self.allocator, "\"");
                },
                .bool => |b| {
                    if (b) {
                        try result.appendSlice(self.allocator, "true");
                    } else {
                        try result.appendSlice(self.allocator, "false");
                    }
                },
                .null => {
                    try result.appendSlice(self.allocator, "null");
                },
                else => {
                    try result.writer(self.allocator).print("{f}", .{std.json.fmt(entry.value_ptr.*, .{})});
                },
            }
            try result.appendSlice(self.allocator, ",");
        }

        // Remove trailing comma
        _ = result.pop();
        try result.append(self.allocator, '}');

        return try result.toOwnedSlice(self.allocator);
    }

    pub const MangleResultMap = std.StringHashMap([]const u8);

    /// Execute a cost-aware routing query.
    ///
    /// Supported query pattern: `route_engine(<node>, X)`
    ///   → resolves X to either `/tensorrt` or `/gguf` based on:
    ///     1. Live GPU queue depth (asserted via assertRuntimeFact before calling)
    ///     2. Static overflow threshold (trt_queue_overflow_threshold)
    ///
    /// Falls back to `/gguf` on any error.
    /// Caller is responsible for freeing the returned slice and deiniting each map.
    pub fn executeQuery(self: *Engine, query: []const u8) ![]MangleResultMap {
        var map = MangleResultMap.init(self.allocator);
        errdefer map.deinit();

        const engine_choice: []const u8 = self.resolveRouteEngine(query);

        try map.put("X", engine_choice);

        const results = try self.allocator.alloc(MangleResultMap, 1);
        results[0] = map;
        return results;
    }

    /// Core cost-routing logic for route_engine(Node, X) queries.
    ///
    /// Decision ladder (evaluated top to bottom, first match wins):
    ///   1. If TRT queue depth >= overflow threshold  → /gguf  (back-pressure)
    ///   2. If TRT queue depth >= high watermark      → /gguf  (pre-emptive protection)
    ///   3. Otherwise                                 → /tensorrt
    ///
    /// The queue depth fact is keyed as "gpu_queue_depth:/tensorrt" (integer).
    fn resolveRouteEngine(self: *Engine, query: []const u8) []const u8 {
        // Only handle route_engine queries
        if (mem.indexOf(u8, query, "route_engine") == null) {
            std.log.warn("[Mangle] Unknown query pattern: {s} — falling back to /gguf", .{query});
            return "/gguf";
        }

        // If TensorRT is not available, always route to /gguf (CUDA forward pass)
        if (!self.tensorrt_available) {
            return "/gguf";
        }

        // Read live TRT queue depth from runtime facts
        const queue_depth = self.getRuntimeFact("gpu_queue_depth:/tensorrt") orelse 0;

        const overflow = self.trt_queue_overflow_threshold;
        const high_wm = self.trt_queue_high_watermark;

        if (queue_depth >= overflow) {
            std.log.warn(
                "[Mangle] TRT queue={d} >= overflow threshold={d}: routing to /gguf (CPU fallback)",
                .{ queue_depth, overflow },
            );
            return "/gguf";
        }

        if (queue_depth >= high_wm) {
            std.log.warn(
                "[Mangle] TRT queue={d} >= high watermark={d}: routing to /gguf (pre-emptive)",
                .{ queue_depth, high_wm },
            );
            return "/gguf";
        }

        std.log.info(
            "[Mangle] TRT queue={d} (overflow={d}): routing to /tensorrt",
            .{ queue_depth, overflow },
        );
        return "/tensorrt";
    }
};

// ============================================================================
// JSON Helpers (Zig 0.15.x compatible)
// ============================================================================

/// Append a string to the result with JSON escaping
fn appendJsonEscaped(result: *std.ArrayListUnmanaged(u8), allocator: Allocator, str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    _ = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch {};
                    try result.appendSlice(allocator, &buf);
                } else {
                    try result.append(allocator, c);
                }
            },
        }
    }
}

// ============================================================================
// Rule Types
// ============================================================================

pub const RuleAction = enum {
    inject_system,
    append_instruction,
    modify_temperature,
};

pub const Rule = struct {
    pattern: []const u8,
    action: RuleAction,
    content: []const u8,
    temperature: ?f32 = null,
};

// ============================================================================
// Prompt Templates
// ============================================================================

pub const PromptTemplate = struct {
    name: []const u8,
    system_prompt: []const u8,
    user_template: []const u8,

    pub fn render(self: PromptTemplate, allocator: Allocator, input: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, self.user_template, .{input});
    }
};

pub const DefaultTemplates = struct {
    pub const code_review = PromptTemplate{
        .name = "code_review",
        .system_prompt = "You are an expert code reviewer. Analyze the code for bugs, performance issues, and best practices.",
        .user_template = "Please review this code:\n\n{s}",
    };

    pub const log_analysis = PromptTemplate{
        .name = "log_analysis",
        .system_prompt = "You are a log analysis expert. Identify errors, patterns, and root causes.",
        .user_template = "Analyze these logs:\n\n{s}",
    };

    pub const summarization = PromptTemplate{
        .name = "summarization",
        .system_prompt = "You are a summarization expert. Provide concise, accurate summaries.",
        .user_template = "Summarize the following:\n\n{s}",
    };
};

// ============================================================================
// Tests
// ============================================================================

test "engine initialization" {
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, null);
    defer engine.deinit();

    try std.testing.expect(engine.rules.count() > 0);
}

test "enhance prompt passthrough" {
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, null);
    defer engine.deinit();

    // Invalid JSON should pass through
    const result = try engine.enhancePrompt("not json");
    try std.testing.expectEqualStrings("not json", result);
}

test "rule creation" {
    const rule = Rule{
        .pattern = "test",
        .action = .inject_system,
        .content = "Test content",
    };
    try std.testing.expectEqualStrings("test", rule.pattern);
}

test "cost-routing: normal load routes to /tensorrt" {
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, null);
    defer engine.deinit();

    // Queue=10, well below both watermarks (48 / 56)
    try engine.assertRuntimeFact("gpu_queue_depth:/tensorrt", 10);

    const results = try engine.executeQuery("route_engine(/node_gpu_01, X)");
    defer {
        for (results) |*m| m.deinit();
        allocator.free(results);
    }
    try std.testing.expect(results.len > 0);
    try std.testing.expectEqualStrings("/tensorrt", results[0].get("X").?);
}

test "cost-routing: overflow routes to /gguf" {
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, null);
    defer engine.deinit();

    // Queue=60 >= overflow threshold of 56
    try engine.assertRuntimeFact("gpu_queue_depth:/tensorrt", 60);

    const results = try engine.executeQuery("route_engine(/node_gpu_01, X)");
    defer {
        for (results) |*m| m.deinit();
        allocator.free(results);
    }
    try std.testing.expect(results.len > 0);
    try std.testing.expectEqualStrings("/gguf", results[0].get("X").?);
}

test "cost-routing: high watermark pre-emptive /gguf" {
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, null);
    defer engine.deinit();

    // Queue=50 >= high watermark=48 but < overflow=56
    try engine.assertRuntimeFact("gpu_queue_depth:/tensorrt", 50);

    const results = try engine.executeQuery("route_engine(/node_gpu_01, X)");
    defer {
        for (results) |*m| m.deinit();
        allocator.free(results);
    }
    try std.testing.expect(results.len > 0);
    try std.testing.expectEqualStrings("/gguf", results[0].get("X").?);
}

test "cost-routing: retract restores default /tensorrt" {
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, null);
    defer engine.deinit();

    // Assert overflow, confirm /gguf
    try engine.assertRuntimeFact("gpu_queue_depth:/tensorrt", 60);
    const r1 = try engine.executeQuery("route_engine(/node_gpu_01, X)");
    defer {
        for (r1) |*m| m.deinit();
        allocator.free(r1);
    }
    try std.testing.expectEqualStrings("/gguf", r1[0].get("X").?);

    // Retract fact → queue defaults to 0 → /tensorrt
    engine.retractRuntimeFact("gpu_queue_depth:/tensorrt");
    const r2 = try engine.executeQuery("route_engine(/node_gpu_01, X)");
    defer {
        for (r2) |*m| m.deinit();
        allocator.free(r2);
    }
    try std.testing.expectEqualStrings("/tensorrt", r2[0].get("X").?);
}

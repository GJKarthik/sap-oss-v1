//! BDC MCP PAL - Zig-Mojo FFI Bridge
//! SIMD-accelerated AI operations for PAL SQL generation

const std = @import("std");
const log = std.log.scoped(.mojo_bridge);

var mojo_lib: ?std.DynLib = null;

pub const MojoFunctions = struct {
    init: ?*const fn () callconv(.C) c_int,
    shutdown: ?*const fn () callconv(.C) void,
    
    /// Chain-of-thought reasoning
    chain_of_thought: ?*const fn (
        prompt: [*]const u8,
        prompt_len: c_int,
        context: [*]const u8,
        context_len: c_int,
        output: [*]u8,
        output_capacity: c_int,
    ) callconv(.C) c_int,
    
    /// ReAct agent step
    react_step: ?*const fn (
        observation: [*]const u8,
        obs_len: c_int,
        action_out: [*]u8,
        action_capacity: c_int,
    ) callconv(.C) c_int,
    
    /// SQL template validation
    validate_sql_template: ?*const fn (
        template: [*]const u8,
        template_len: c_int,
        schema_json: [*]const u8,
        schema_len: c_int,
    ) callconv(.C) c_int,
    
    /// Token counting (SIMD)
    count_tokens: ?*const fn (
        text: [*]const u8,
        text_len: c_int,
    ) callconv(.C) c_int,
    
    /// Similarity scoring for tool selection
    score_tool_match: ?*const fn (
        query: [*]const u8,
        query_len: c_int,
        tool_descs: [*]const u8,
        desc_lengths: [*]const c_int,
        tool_count: c_int,
        scores_out: [*]f32,
    ) callconv(.C) c_int,
};

var mojo_functions: MojoFunctions = .{
    .init = null,
    .shutdown = null,
    .chain_of_thought = null,
    .react_step = null,
    .validate_sql_template = null,
    .count_tokens = null,
    .score_tool_match = null,
};

pub const MojoBridge = struct {
    allocator: std.mem.Allocator,
    is_initialized: bool,
    lib_path: []const u8,

    calls_total: std.atomic.Value(u64),
    cot_calls: std.atomic.Value(u64),
    react_steps: std.atomic.Value(u64),

    pub const Config = struct {
        lib_path: []const u8 = "libmojo_mcppal.so",
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !MojoBridge {
        var bridge = MojoBridge{
            .allocator = allocator,
            .is_initialized = false,
            .lib_path = config.lib_path,
            .calls_total = std.atomic.Value(u64).init(0),
            .cot_calls = std.atomic.Value(u64).init(0),
            .react_steps = std.atomic.Value(u64).init(0),
        };

        bridge.loadLibrary() catch |err| {
            log.warn("Mojo library not loaded: {} - using fallbacks", .{err});
        };

        return bridge;
    }

    pub fn deinit(self: *MojoBridge) void {
        if (mojo_lib) |*lib| {
            if (mojo_functions.shutdown) |shutdown| shutdown();
            lib.close();
            mojo_lib = null;
        }
        _ = self;
    }

    fn loadLibrary(self: *MojoBridge) !void {
        const paths = [_][]const u8{
            self.lib_path,
            "./libmojo_mcppal.so",
            "./libmojo_mcppal.dylib",
            "/usr/local/lib/libmojo_mcppal.so",
        };

        for (paths) |path| {
            mojo_lib = std.DynLib.open(path) catch continue;
            break;
        }

        if (mojo_lib) |lib| {
            mojo_functions.init = lib.lookup(*const fn () callconv(.C) c_int, "mojo_init");
            mojo_functions.shutdown = lib.lookup(*const fn () callconv(.C) void, "mojo_shutdown");
            mojo_functions.chain_of_thought = lib.lookup(
                *const fn ([*]const u8, c_int, [*]const u8, c_int, [*]u8, c_int) callconv(.C) c_int,
                "mojo_chain_of_thought",
            );
            mojo_functions.react_step = lib.lookup(
                *const fn ([*]const u8, c_int, [*]u8, c_int) callconv(.C) c_int,
                "mojo_react_step",
            );
            mojo_functions.validate_sql_template = lib.lookup(
                *const fn ([*]const u8, c_int, [*]const u8, c_int) callconv(.C) c_int,
                "mojo_validate_sql_template",
            );
            mojo_functions.count_tokens = lib.lookup(
                *const fn ([*]const u8, c_int) callconv(.C) c_int,
                "mojo_count_tokens",
            );
            mojo_functions.score_tool_match = lib.lookup(
                *const fn ([*]const u8, c_int, [*]const u8, [*]const c_int, c_int, [*]f32) callconv(.C) c_int,
                "mojo_score_tool_match",
            );

            if (mojo_functions.init) |init_fn| {
                if (init_fn() != 0) return error.MojoInitFailed;
            }

            self.is_initialized = true;
            log.info("Mojo library loaded", .{});
        }
    }

    /// Chain-of-thought reasoning
    pub fn chainOfThought(
        self: *MojoBridge,
        prompt: []const u8,
        context: []const u8,
        output: []u8,
    ) !usize {
        _ = self.calls_total.fetchAdd(1, .monotonic);
        _ = self.cot_calls.fetchAdd(1, .monotonic);

        if (mojo_functions.chain_of_thought) |cot_fn| {
            const result = cot_fn(
                prompt.ptr,
                @intCast(prompt.len),
                context.ptr,
                @intCast(context.len),
                output.ptr,
                @intCast(output.len),
            );
            if (result < 0) return error.ChainOfThoughtFailed;
            return @intCast(result);
        }

        // Fallback: simple template
        const msg = "Analyzing request with available context...";
        const copy_len = @min(msg.len, output.len);
        @memcpy(output[0..copy_len], msg[0..copy_len]);
        return copy_len;
    }

    /// ReAct agent step
    pub fn reactStep(
        self: *MojoBridge,
        observation: []const u8,
        action_out: []u8,
    ) !usize {
        _ = self.calls_total.fetchAdd(1, .monotonic);
        _ = self.react_steps.fetchAdd(1, .monotonic);

        if (mojo_functions.react_step) |react_fn| {
            const result = react_fn(
                observation.ptr,
                @intCast(observation.len),
                action_out.ptr,
                @intCast(action_out.len),
            );
            if (result < 0) return error.ReactStepFailed;
            return @intCast(result);
        }

        // Fallback
        const msg = "THINK: Processing observation\nACT: query_database";
        const copy_len = @min(msg.len, action_out.len);
        @memcpy(action_out[0..copy_len], msg[0..copy_len]);
        return copy_len;
    }

    /// Validate SQL template against schema
    pub fn validateSqlTemplate(
        self: *MojoBridge,
        template: []const u8,
        schema_json: []const u8,
    ) !bool {
        _ = self.calls_total.fetchAdd(1, .monotonic);

        if (mojo_functions.validate_sql_template) |validate_fn| {
            const result = validate_fn(
                template.ptr,
                @intCast(template.len),
                schema_json.ptr,
                @intCast(schema_json.len),
            );
            return result == 0;
        }

        // Fallback: basic validation
        return std.mem.indexOf(u8, template, "DROP") == null and
            std.mem.indexOf(u8, template, "TRUNCATE") == null;
    }

    /// Count tokens (approximate)
    pub fn countTokens(self: *MojoBridge, text: []const u8) usize {
        _ = self.calls_total.fetchAdd(1, .monotonic);

        if (mojo_functions.count_tokens) |count_fn| {
            const result = count_fn(text.ptr, @intCast(text.len));
            if (result >= 0) return @intCast(result);
        }

        // Fallback: ~4 chars per token
        return (text.len + 3) / 4;
    }

    /// Score tool descriptions for query matching
    pub fn scoreToolMatch(
        self: *MojoBridge,
        query: []const u8,
        tool_descriptions: []const []const u8,
        scores: []f32,
    ) !void {
        _ = self.calls_total.fetchAdd(1, .monotonic);

        if (mojo_functions.score_tool_match != null) {
            // Pack descriptions
            var total_len: usize = 0;
            for (tool_descriptions) |desc| total_len += desc.len;

            var packed = try self.allocator.alloc(u8, total_len);
            defer self.allocator.free(packed);
            var lengths = try self.allocator.alloc(c_int, tool_descriptions.len);
            defer self.allocator.free(lengths);

            var offset: usize = 0;
            for (tool_descriptions, 0..) |desc, i| {
                @memcpy(packed[offset..][0..desc.len], desc);
                lengths[i] = @intCast(desc.len);
                offset += desc.len;
            }

            const result = mojo_functions.score_tool_match.?(
                query.ptr,
                @intCast(query.len),
                packed.ptr,
                lengths.ptr,
                @intCast(tool_descriptions.len),
                scores.ptr,
            );
            if (result >= 0) return;
        }

        // Fallback: keyword matching
        for (tool_descriptions, 0..) |desc, i| {
            var score: f32 = 0.0;
            var words = std.mem.splitScalar(u8, query, ' ');
            while (words.next()) |word| {
                if (word.len > 2 and std.mem.indexOf(u8, desc, word) != null) {
                    score += 1.0;
                }
            }
            scores[i] = score / @as(f32, @floatFromInt(@max(1, query.len / 5)));
        }
    }

    pub fn getStats(self: *MojoBridge) BridgeStats {
        return .{
            .is_initialized = self.is_initialized,
            .calls_total = self.calls_total.load(.monotonic),
            .cot_calls = self.cot_calls.load(.monotonic),
            .react_steps = self.react_steps.load(.monotonic),
        };
    }
};

pub const BridgeStats = struct {
    is_initialized: bool,
    calls_total: u64,
    cot_calls: u64,
    react_steps: u64,
};

test "MojoBridge fallback token counting" {
    const allocator = std.testing.allocator;
    var bridge = try MojoBridge.init(allocator, .{ .lib_path = "nonexistent.so" });
    defer bridge.deinit();

    const tokens = bridge.countTokens("Hello world test");
    try std.testing.expect(tokens > 0);
}
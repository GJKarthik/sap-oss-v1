//! BDC AIPrompt Streaming - Lightweight Functions Framework
//! Serverless stream processing functions on AIPrompt topics

const std = @import("std");
const hana = @import("../hana/hana_db.zig");

const log = std.log.scoped(.functions);

// ============================================================================
// Function Configuration
// ============================================================================

pub const FunctionConfig = struct {
    /// Function name
    name: []const u8,
    /// Namespace
    namespace: []const u8 = "default",
    /// Tenant
    tenant: []const u8 = "public",
    /// Input topics
    inputs: []const []const u8,
    /// Output topic (null for sink functions)
    output: ?[]const u8 = null,
    /// Log topic for function logs
    log_topic: ?[]const u8 = null,
    /// Dead letter topic for failed messages
    dead_letter_topic: ?[]const u8 = null,
    /// Processing guarantees
    processing_guarantees: ProcessingGuarantees = .atleast_once,
    /// Parallelism (number of instances)
    parallelism: u32 = 1,
    /// Auto-ack messages
    auto_ack: bool = true,
    /// Max message retries
    max_message_retries: u32 = 3,
    /// Timeout in milliseconds
    timeout_ms: u32 = 30000,
    /// Custom runtime settings
    runtime_flags: RuntimeFlags = .{},
};

pub const ProcessingGuarantees = enum {
    atleast_once,
    atmost_once,
    effectively_once,
};

pub const RuntimeFlags = struct {
    forward_source_message_property: bool = true,
    retain_ordering: bool = false,
    batch_builder: BatchBuilder = .default,
    max_pending_async_requests: u32 = 1000,
};

pub const BatchBuilder = enum {
    default,
    key_based,
};

// ============================================================================
// Function Context
// ============================================================================

pub const FunctionContext = struct {
    allocator: std.mem.Allocator,
    function_config: *const FunctionConfig,
    message_id: MessageId,
    input_topic: []const u8,
    publish_time: i64,
    event_time: ?i64,
    properties: std.StringHashMap([]const u8),
    key: ?[]const u8,
    partition_id: i32,

    // State store
    state: *StateStore,

    // Output
    output_messages: std.ArrayList(OutputMessage),

    // Metrics
    user_metrics: std.StringHashMap(f64),

    pub fn init(allocator: std.mem.Allocator, config: *const FunctionConfig, state: *StateStore) FunctionContext {
        return .{
            .allocator = allocator,
            .function_config = config,
            .message_id = .{ .ledger_id = 0, .entry_id = 0 },
            .input_topic = "",
            .publish_time = 0,
            .event_time = null,
            .properties = std.StringHashMap([]const u8).init(allocator),
            .key = null,
            .partition_id = -1,
            .state = state,
            .output_messages = std.ArrayList(OutputMessage).init(allocator),
            .user_metrics = std.StringHashMap(f64).init(allocator),
        };
    }

    pub fn deinit(self: *FunctionContext) void {
        self.properties.deinit();
        self.output_messages.deinit();
        self.user_metrics.deinit();
    }

    /// Get current function name
    pub fn getFunctionName(self: *const FunctionContext) []const u8 {
        return self.function_config.name;
    }

    /// Get input topics
    pub fn getInputTopics(self: *const FunctionContext) []const []const u8 {
        return self.function_config.inputs;
    }

    /// Get output topic
    pub fn getOutputTopic(self: *const FunctionContext) ?[]const u8 {
        return self.function_config.output;
    }

    /// Publish message to output topic
    pub fn publish(self: *FunctionContext, value: []const u8) !void {
        try self.output_messages.append(.{
            .topic = self.function_config.output,
            .key = null,
            .value = value,
            .properties = null,
        });
    }

    /// Publish message with key
    pub fn publishWithKey(self: *FunctionContext, key: []const u8, value: []const u8) !void {
        try self.output_messages.append(.{
            .topic = self.function_config.output,
            .key = key,
            .value = value,
            .properties = null,
        });
    }

    /// Publish to specific topic
    pub fn publishToTopic(self: *FunctionContext, topic: []const u8, value: []const u8) !void {
        try self.output_messages.append(.{
            .topic = topic,
            .key = null,
            .value = value,
            .properties = null,
        });
    }

    /// Get message property
    pub fn getProperty(self: *const FunctionContext, key: []const u8) ?[]const u8 {
        return self.properties.get(key);
    }

    /// Record custom metric
    pub fn recordMetric(self: *FunctionContext, name: []const u8, value: f64) !void {
        try self.user_metrics.put(name, value);
    }

    /// Increment counter metric
    pub fn incrCounter(self: *FunctionContext, name: []const u8, delta: f64) !void {
        const current = self.user_metrics.get(name) orelse 0.0;
        try self.user_metrics.put(name, current + delta);
    }
};

pub const MessageId = struct {
    ledger_id: i64,
    entry_id: i64,

    pub fn format(self: MessageId, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{}:{}", .{ self.ledger_id, self.entry_id });
    }
};

pub const OutputMessage = struct {
    topic: ?[]const u8,
    key: ?[]const u8,
    value: []const u8,
    properties: ?std.StringHashMap([]const u8),
};

// ============================================================================
// State Store (for Stateful Functions)
// ============================================================================

pub const StateStore = struct {
    allocator: std.mem.Allocator,
    function_name: []const u8,
    state: std.StringHashMap([]const u8),
    hana_client: ?*hana.HanaClient,
    dirty_keys: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator, function_name: []const u8) StateStore {
        return .{
            .allocator = allocator,
            .function_name = function_name,
            .state = std.StringHashMap([]const u8).init(allocator),
            .hana_client = null,
            .dirty_keys = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *StateStore) void {
        self.state.deinit();
        self.dirty_keys.deinit();
    }

    /// Get state value
    pub fn get(self: *StateStore, key: []const u8) ?[]const u8 {
        return self.state.get(key);
    }

    /// Put state value
    pub fn put(self: *StateStore, key: []const u8, value: []const u8) !void {
        try self.state.put(key, value);
        try self.dirty_keys.put(key, {});
    }

    /// Delete state key
    pub fn delete(self: *StateStore, key: []const u8) bool {
        const removed = self.state.remove(key);
        _ = self.dirty_keys.remove(key);
        return removed;
    }

    /// Increment counter (atomic)
    pub fn incrCounter(self: *StateStore, key: []const u8, delta: i64) !i64 {
        const current_str = self.state.get(key);
        var current: i64 = 0;

        if (current_str) |str| {
            current = std.fmt.parseInt(i64, str, 10) catch 0;
        }

        current += delta;

        var buf: [32]u8 = undefined;
        const new_str = std.fmt.bufPrint(&buf, "{}", .{current}) catch "";
        try self.put(key, new_str);

        return current;
    }

    /// Flush dirty state to HANA
    pub fn flush(self: *StateStore) !void {
        if (self.hana_client == null or self.dirty_keys.count() == 0) return;

        log.debug("Flushing {} dirty state keys to HANA", .{self.dirty_keys.count()});

        var iter = self.dirty_keys.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = self.state.get(key) orelse continue;

            var qb = hana.QueryBuilder.init(self.allocator);
            defer qb.deinit();

            try qb.appendFmt(
                \\UPSERT "AIPROMPT_STORAGE".AIPROMPT_FUNCTION_STATE 
                \\(FUNCTION_NAME, STATE_KEY, STATE_VALUE, UPDATED_AT)
                \\VALUES ('{s}', '{s}', '{s}', {})
                \\WITH PRIMARY KEY
            , .{
                self.function_name,
                key,
                value,
                std.time.milliTimestamp(),
            });

            try self.hana_client.?.execute(qb.build());
        }

        self.dirty_keys.clearRetainingCapacity();
    }
};

// ============================================================================
// Function Interface
// ============================================================================

/// Base interface for AIPrompt Functions
pub fn Function(comptime InputT: type, comptime OutputT: type) type {
    return struct {
        pub const Input = InputT;
        pub const Output = OutputT;

        /// Process function - must be implemented
        pub const ProcessFn = *const fn (*FunctionContext, InputT) ?OutputT;
    };
}

/// Simple string-to-string function
pub const StringFunction = Function([]const u8, []const u8);

/// Void sink function (no output)
pub const SinkFunction = Function([]const u8, void);

// ============================================================================
// Function Runtime
// ============================================================================

pub const FunctionRuntime = struct {
    allocator: std.mem.Allocator,
    config: FunctionConfig,
    state_store: StateStore,
    is_running: bool,

    // Metrics
    messages_processed: std.atomic.Value(u64),
    messages_failed: std.atomic.Value(u64),
    processing_time_ns: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, config: FunctionConfig) FunctionRuntime {
        return .{
            .allocator = allocator,
            .config = config,
            .state_store = StateStore.init(allocator, config.name),
            .is_running = false,
            .messages_processed = std.atomic.Value(u64).init(0),
            .messages_failed = std.atomic.Value(u64).init(0),
            .processing_time_ns = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *FunctionRuntime) void {
        self.state_store.deinit();
    }

    /// Start function runtime
    pub fn start(self: *FunctionRuntime) !void {
        log.info("Starting function: {s}/{s}/{s}", .{
            self.config.tenant,
            self.config.namespace,
            self.config.name,
        });

        self.is_running = true;

        // In production: subscribe to input topics and start processing loop
    }

    /// Stop function runtime
    pub fn stop(self: *FunctionRuntime) !void {
        log.info("Stopping function: {s}", .{self.config.name});

        self.is_running = false;

        // Flush state
        try self.state_store.flush();
    }

    /// Process a single message
    pub fn processMessage(self: *FunctionRuntime, comptime processFn: anytype, input: []const u8) !?[]const u8 {
        const start_time = std.time.nanoTimestamp();

        var ctx = FunctionContext.init(self.allocator, &self.config, &self.state_store);
        defer ctx.deinit();

        // Call user function
        const result = processFn(&ctx, input);

        const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start_time));
        _ = self.processing_time_ns.fetchAdd(elapsed, .monotonic);
        _ = self.messages_processed.fetchAdd(1, .monotonic);

        return result;
    }

    /// Get function stats
    pub fn getStats(self: *FunctionRuntime) FunctionStats {
        const processed = self.messages_processed.load(.monotonic);
        const time_ns = self.processing_time_ns.load(.monotonic);
        return .{
            .name = self.config.name,
            .namespace = self.config.namespace,
            .tenant = self.config.tenant,
            .messages_processed = processed,
            .messages_failed = self.messages_failed.load(.monotonic),
            .avg_latency_ms = if (processed > 0) @divFloor(time_ns / 1_000_000, processed) else 0,
            .is_running = self.is_running,
        };
    }
};

pub const FunctionStats = struct {
    name: []const u8,
    namespace: []const u8,
    tenant: []const u8,
    messages_processed: u64,
    messages_failed: u64,
    avg_latency_ms: u64,
    is_running: bool,
};

// ============================================================================
// Function Registry
// ============================================================================

pub const FunctionRegistry = struct {
    allocator: std.mem.Allocator,
    functions: std.StringHashMap(*FunctionRuntime),
    lock: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) FunctionRegistry {
        return .{
            .allocator = allocator,
            .functions = std.StringHashMap(*FunctionRuntime).init(allocator),
            .lock = .{},
        };
    }

    pub fn deinit(self: *FunctionRegistry) void {
        var iter = self.functions.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.functions.deinit();
    }

    /// Register a new function
    pub fn register(self: *FunctionRegistry, config: FunctionConfig) !*FunctionRuntime {
        self.lock.lock();
        defer self.lock.unlock();

        var key_buf: [256]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{s}/{s}/{s}", .{
            config.tenant,
            config.namespace,
            config.name,
        });

        if (self.functions.contains(key)) {
            return error.FunctionAlreadyExists;
        }

        const runtime = try self.allocator.create(FunctionRuntime);
        runtime.* = FunctionRuntime.init(self.allocator, config);

        try self.functions.put(key, runtime);

        log.info("Registered function: {s}", .{key});
        return runtime;
    }

    /// Unregister a function
    pub fn unregister(self: *FunctionRegistry, tenant: []const u8, namespace: []const u8, name: []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();

        var key_buf: [256]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{s}/{s}/{s}", .{ tenant, namespace, name });

        if (self.functions.fetchRemove(key)) |entry| {
            entry.value.deinit();
            self.allocator.destroy(entry.value);
            log.info("Unregistered function: {s}", .{key});
        }
    }

    /// Get function by name
    pub fn get(self: *FunctionRegistry, tenant: []const u8, namespace: []const u8, name: []const u8) ?*FunctionRuntime {
        self.lock.lock();
        defer self.lock.unlock();

        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}/{s}/{s}", .{ tenant, namespace, name }) catch return null;

        return self.functions.get(key);
    }

    /// List all registered functions
    pub fn list(self: *FunctionRegistry) []const []const u8 {
        self.lock.lock();
        defer self.lock.unlock();
        return self.functions.keys();
    }
};

// ============================================================================
// Built-in Functions
// ============================================================================

pub const BuiltinFunctions = struct {
    /// Identity function - pass through unchanged
    pub fn identity(_: *FunctionContext, input: []const u8) ?[]const u8 {
        return input;
    }

    /// Log function - log message and pass through
    pub fn logMessage(ctx: *FunctionContext, input: []const u8) ?[]const u8 {
        log.info("[{s}] Message: {s}", .{ ctx.getFunctionName(), input });
        return input;
    }

    /// Filter by length
    pub fn filterByLength(ctx: *FunctionContext, input: []const u8) ?[]const u8 {
        const min_len_str = ctx.getProperty("min_length") orelse "0";
        const min_len = std.fmt.parseInt(usize, min_len_str, 10) catch 0;

        if (input.len >= min_len) {
            return input;
        }
        return null;
    }

    /// Count messages (stateful)
    pub fn countMessages(ctx: *FunctionContext, input: []const u8) ?[]const u8 {
        _ = ctx.state.incrCounter("message_count", 1) catch 0;
        return input;
    }
};

// ============================================================================
// HANA DDL for Functions
// ============================================================================

pub const FunctionSchemaDDL = struct {
    pub fn getCreateFunctionStateTableSQL() []const u8 {
        return
            \\CREATE COLUMN TABLE "AIPROMPT_STORAGE".AIPROMPT_FUNCTION_STATE (
            \\    FUNCTION_NAME NVARCHAR(256) NOT NULL,
            \\    STATE_KEY NVARCHAR(512) NOT NULL,
            \\    STATE_VALUE NCLOB,
            \\    UPDATED_AT BIGINT NOT NULL,
            \\    PRIMARY KEY (FUNCTION_NAME, STATE_KEY)
            \\)
        ;
    }

    pub fn getCreateFunctionMetadataTableSQL() []const u8 {
        return
            \\CREATE COLUMN TABLE "AIPROMPT_STORAGE".AIPROMPT_FUNCTIONS (
            \\    TENANT NVARCHAR(128) NOT NULL,
            \\    NAMESPACE NVARCHAR(128) NOT NULL,
            \\    NAME NVARCHAR(256) NOT NULL,
            \\    CONFIG NCLOB,
            \\    STATUS NVARCHAR(32) NOT NULL,
            \\    PARALLELISM INTEGER DEFAULT 1,
            \\    CREATED_AT BIGINT NOT NULL,
            \\    UPDATED_AT BIGINT NOT NULL,
            \\    PRIMARY KEY (TENANT, NAMESPACE, NAME)
            \\)
        ;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "StateStore operations" {
    const allocator = std.testing.allocator;

    var store = StateStore.init(allocator, "test-function");
    defer store.deinit();

    try store.put("key1", "value1");
    try std.testing.expectEqualStrings("value1", store.get("key1").?);

    const count = try store.incrCounter("counter", 5);
    try std.testing.expectEqual(@as(i64, 5), count);

    _ = store.delete("key1");
    try std.testing.expect(store.get("key1") == null);
}

test "FunctionConfig defaults" {
    const inputs = [_][]const u8{"topic1"};
    const config = FunctionConfig{
        .name = "test",
        .inputs = &inputs,
    };

    try std.testing.expectEqualStrings("default", config.namespace);
    try std.testing.expectEqualStrings("public", config.tenant);
    try std.testing.expectEqual(@as(u32, 1), config.parallelism);
}
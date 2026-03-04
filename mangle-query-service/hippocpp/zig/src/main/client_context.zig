//! Client Context - Query execution context and settings
//!
//! Purpose:
//! Manages per-client session state, query execution context,
//! and client-specific settings for query processing.

const std = @import("std");

// ============================================================================
// Client Settings
// ============================================================================

pub const ClientSettings = struct {
    // Query execution
    query_timeout_ms: u64 = 0,           // 0 = no timeout
    max_result_rows: u64 = 100_000,
    enable_progress_bar: bool = false,
    
    // Output format
    output_format: OutputFormat = .TABLE,
    null_display: []const u8 = "NULL",
    
    // Optimization
    enable_optimizer: bool = true,
    enable_parallel: bool = true,
    max_threads: u32 = 0,                // 0 = auto
    
    // Memory
    memory_limit: usize = 0,             // 0 = no limit
    
    // Profiling
    enable_profiling: bool = false,
    explain_analyze: bool = false,
};

pub const OutputFormat = enum {
    TABLE,
    CSV,
    JSON,
    MARKDOWN,
    RAW,
};

// ============================================================================
// Variable Scope
// ============================================================================

pub const Variable = struct {
    name: []const u8,
    value: Value,
    constant: bool = false,
};

pub const Value = union(enum) {
    null_val: void,
    bool_val: bool,
    int_val: i64,
    float_val: f64,
    string_val: []const u8,
    
    pub fn asBool(self: Value) ?bool {
        return switch (self) {
            .bool_val => |v| v,
            else => null,
        };
    }
    
    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .int_val => |v| v,
            else => null,
        };
    }
    
    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string_val => |v| v,
            else => null,
        };
    }
};

// ============================================================================
// Query Progress
// ============================================================================

pub const QueryProgress = struct {
    total_rows: u64 = 0,
    processed_rows: u64 = 0,
    phase: []const u8 = "",
    start_time: i64 = 0,
    
    pub fn getPercentage(self: *const QueryProgress) f64 {
        if (self.total_rows == 0) return 0;
        return @as(f64, @floatFromInt(self.processed_rows)) / @as(f64, @floatFromInt(self.total_rows)) * 100.0;
    }
    
    pub fn getElapsedMs(self: *const QueryProgress) u64 {
        if (self.start_time == 0) return 0;
        return @intCast(std.time.timestamp() - self.start_time);
    }
};

// ============================================================================
// Profiling Info
// ============================================================================

pub const OperatorProfile = struct {
    operator_name: []const u8,
    rows_input: u64 = 0,
    rows_output: u64 = 0,
    time_ms: u64 = 0,
    memory_used: usize = 0,
};

pub const QueryProfile = struct {
    allocator: std.mem.Allocator,
    query_text: []const u8,
    operators: std.ArrayList(OperatorProfile),
    total_time_ms: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator, query: []const u8) QueryProfile {
        return .{
            .allocator = allocator,
            .query_text = query,
            .operators = std.ArrayList(OperatorProfile).init(allocator),
        };
    }
    
    pub fn deinit(self: *QueryProfile) void {
        self.operators.deinit();
    }
    
    pub fn addOperator(self: *QueryProfile, profile: OperatorProfile) !void {
        try self.operators.append(profile);
    }
};

// ============================================================================
// Client Context
// ============================================================================

pub const ClientContext = struct {
    allocator: std.mem.Allocator,
    context_id: u64,
    
    // Settings
    settings: ClientSettings = .{},
    
    // Variables
    variables: std.StringHashMap(Variable),
    
    // Current transaction
    transaction_id: ?u64 = null,
    auto_commit: bool = true,
    
    // Query state
    current_query: ?[]const u8 = null,
    progress: QueryProgress = .{},
    interrupted: bool = false,
    
    // Profiling
    current_profile: ?*QueryProfile = null,
    
    // Warning messages
    warnings: std.ArrayList([]const u8),
    
    pub fn init(allocator: std.mem.Allocator, context_id: u64) ClientContext {
        return .{
            .allocator = allocator,
            .context_id = context_id,
            .variables = std.StringHashMap(Variable).init(allocator),
            .warnings = std.ArrayList([]const u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *ClientContext) void {
        self.variables.deinit();
        self.warnings.deinit();
        if (self.current_profile) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
    }
    
    /// Set a variable
    pub fn setVariable(self: *ClientContext, name: []const u8, value: Value) !void {
        const variable = Variable{
            .name = name,
            .value = value,
        };
        try self.variables.put(name, variable);
    }
    
    /// Get a variable
    pub fn getVariable(self: *const ClientContext, name: []const u8) ?Value {
        if (self.variables.get(name)) |v| {
            return v.value;
        }
        return null;
    }
    
    /// Remove a variable
    pub fn unsetVariable(self: *ClientContext, name: []const u8) void {
        _ = self.variables.remove(name);
    }
    
    /// Begin query execution
    pub fn beginQuery(self: *ClientContext, query: []const u8) void {
        self.current_query = query;
        self.progress = .{
            .start_time = std.time.timestamp(),
        };
        self.interrupted = false;
        
        if (self.settings.enable_profiling) {
            if (self.current_profile) |p| {
                p.deinit();
                self.allocator.destroy(p);
            }
            const profile = self.allocator.create(QueryProfile) catch return;
            profile.* = QueryProfile.init(self.allocator, query);
            self.current_profile = profile;
        }
    }
    
    /// End query execution
    pub fn endQuery(self: *ClientContext) void {
        if (self.current_profile) |p| {
            p.total_time_ms = self.progress.getElapsedMs();
        }
        self.current_query = null;
    }
    
    /// Update progress
    pub fn updateProgress(self: *ClientContext, processed: u64, total: u64) void {
        self.progress.processed_rows = processed;
        self.progress.total_rows = total;
    }
    
    /// Interrupt current query
    pub fn interrupt(self: *ClientContext) void {
        self.interrupted = true;
    }
    
    /// Check if interrupted
    pub fn isInterrupted(self: *const ClientContext) bool {
        return self.interrupted;
    }
    
    /// Add a warning
    pub fn addWarning(self: *ClientContext, message: []const u8) !void {
        try self.warnings.append(message);
    }
    
    /// Clear warnings
    pub fn clearWarnings(self: *ClientContext) void {
        self.warnings.clearRetainingCapacity();
    }
    
    /// Check if in transaction
    pub fn inTransaction(self: *const ClientContext) bool {
        return self.transaction_id != null;
    }
    
    /// Get setting value
    pub fn getSetting(self: *const ClientContext, name: []const u8) ?Value {
        // Built-in settings
        if (std.mem.eql(u8, name, "query_timeout")) {
            return Value{ .int_val = @intCast(self.settings.query_timeout_ms) };
        } else if (std.mem.eql(u8, name, "enable_optimizer")) {
            return Value{ .bool_val = self.settings.enable_optimizer };
        } else if (std.mem.eql(u8, name, "enable_profiling")) {
            return Value{ .bool_val = self.settings.enable_profiling };
        }
        return null;
    }
    
    /// Set setting value
    pub fn setSetting(self: *ClientContext, name: []const u8, value: Value) !void {
        if (std.mem.eql(u8, name, "query_timeout")) {
            if (value.asInt()) |v| {
                self.settings.query_timeout_ms = @intCast(v);
            }
        } else if (std.mem.eql(u8, name, "enable_optimizer")) {
            if (value.asBool()) |v| {
                self.settings.enable_optimizer = v;
            }
        } else if (std.mem.eql(u8, name, "enable_profiling")) {
            if (value.asBool()) |v| {
                self.settings.enable_profiling = v;
            }
        } else {
            return error.UnknownSetting;
        }
    }
};

// ============================================================================
// Context Factory
// ============================================================================

pub const ContextFactory = struct {
    allocator: std.mem.Allocator,
    next_id: u64 = 1,
    
    pub fn init(allocator: std.mem.Allocator) ContextFactory {
        return .{ .allocator = allocator };
    }
    
    pub fn create(self: *ContextFactory) !*ClientContext {
        const ctx = try self.allocator.create(ClientContext);
        ctx.* = ClientContext.init(self.allocator, self.next_id);
        self.next_id += 1;
        return ctx;
    }
    
    pub fn destroy(self: *ContextFactory, ctx: *ClientContext) void {
        ctx.deinit();
        self.allocator.destroy(ctx);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "client context basic" {
    const allocator = std.testing.allocator;
    
    var ctx = ClientContext.init(allocator, 1);
    defer ctx.deinit();
    
    try std.testing.expectEqual(@as(u64, 1), ctx.context_id);
    try std.testing.expect(!ctx.inTransaction());
}

test "client context variables" {
    const allocator = std.testing.allocator;
    
    var ctx = ClientContext.init(allocator, 1);
    defer ctx.deinit();
    
    try ctx.setVariable("x", Value{ .int_val = 42 });
    
    const val = ctx.getVariable("x");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(i64, 42), val.?.asInt().?);
    
    ctx.unsetVariable("x");
    try std.testing.expect(ctx.getVariable("x") == null);
}

test "client context query" {
    const allocator = std.testing.allocator;
    
    var ctx = ClientContext.init(allocator, 1);
    defer ctx.deinit();
    
    ctx.beginQuery("SELECT * FROM users");
    try std.testing.expect(ctx.current_query != null);
    
    ctx.updateProgress(50, 100);
    try std.testing.expectEqual(@as(f64, 50.0), ctx.progress.getPercentage());
    
    ctx.endQuery();
    try std.testing.expect(ctx.current_query == null);
}

test "client context interrupt" {
    const allocator = std.testing.allocator;
    
    var ctx = ClientContext.init(allocator, 1);
    defer ctx.deinit();
    
    try std.testing.expect(!ctx.isInterrupted());
    ctx.interrupt();
    try std.testing.expect(ctx.isInterrupted());
}

test "context factory" {
    const allocator = std.testing.allocator;
    
    var factory = ContextFactory.init(allocator);
    
    const ctx1 = try factory.create();
    defer factory.destroy(ctx1);
    
    const ctx2 = try factory.create();
    defer factory.destroy(ctx2);
    
    try std.testing.expectEqual(@as(u64, 1), ctx1.context_id);
    try std.testing.expectEqual(@as(u64, 2), ctx2.context_id);
}

test "value types" {
    const int_val = Value{ .int_val = 42 };
    try std.testing.expectEqual(@as(i64, 42), int_val.asInt().?);
    try std.testing.expect(int_val.asBool() == null);
    
    const bool_val = Value{ .bool_val = true };
    try std.testing.expect(bool_val.asBool().?);
}
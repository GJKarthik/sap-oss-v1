//! Profiler - Performance profiling and metrics collection
//!
//! Purpose:
//! Provides timing, memory tracking, and operator profiling
//! for query execution analysis and optimization.

const std = @import("std");

// ============================================================================
// Timer
// ============================================================================

pub const Timer = struct {
    start_time: i128 = 0,
    accumulated: i128 = 0,
    running: bool = false,
    
    pub fn start(self: *Timer) void {
        if (!self.running) {
            self.start_time = std.time.nanoTimestamp();
            self.running = true;
        }
    }
    
    pub fn stop(self: *Timer) void {
        if (self.running) {
            self.accumulated += std.time.nanoTimestamp() - self.start_time;
            self.running = false;
        }
    }
    
    pub fn reset(self: *Timer) void {
        self.accumulated = 0;
        self.running = false;
    }
    
    pub fn elapsedNanos(self: *const Timer) i128 {
        if (self.running) {
            return self.accumulated + (std.time.nanoTimestamp() - self.start_time);
        }
        return self.accumulated;
    }
    
    pub fn elapsedMicros(self: *const Timer) u64 {
        return @intCast(@divFloor(self.elapsedNanos(), 1000));
    }
    
    pub fn elapsedMillis(self: *const Timer) u64 {
        return @intCast(@divFloor(self.elapsedNanos(), 1_000_000));
    }
    
    pub fn elapsedSeconds(self: *const Timer) f64 {
        return @as(f64, @floatFromInt(self.elapsedNanos())) / 1_000_000_000.0;
    }
};

// ============================================================================
// Scoped Timer
// ============================================================================

pub fn ScopedTimer(comptime Context: type) type {
    return struct {
        timer: *Timer,
        context: Context,
        
        const Self = @This();
        
        pub fn init(timer: *Timer, context: Context) Self {
            timer.start();
            return .{ .timer = timer, .context = context };
        }
        
        pub fn deinit(self: *Self) void {
            self.timer.stop();
        }
    };
}

// ============================================================================
// Memory Tracker
// ============================================================================

pub const MemoryTracker = struct {
    current_usage: usize = 0,
    peak_usage: usize = 0,
    allocation_count: u64 = 0,
    deallocation_count: u64 = 0,
    limit: usize = 0,  // 0 = no limit
    
    pub fn allocate(self: *MemoryTracker, size: usize) !void {
        if (self.limit > 0 and self.current_usage + size > self.limit) {
            return error.MemoryLimitExceeded;
        }
        
        self.current_usage += size;
        self.allocation_count += 1;
        self.peak_usage = @max(self.peak_usage, self.current_usage);
    }
    
    pub fn deallocate(self: *MemoryTracker, size: usize) void {
        self.current_usage -|= size;
        self.deallocation_count += 1;
    }
    
    pub fn reset(self: *MemoryTracker) void {
        self.current_usage = 0;
        self.peak_usage = 0;
        self.allocation_count = 0;
        self.deallocation_count = 0;
    }
    
    pub fn setLimit(self: *MemoryTracker, limit: usize) void {
        self.limit = limit;
    }
};

// ============================================================================
// Counter
// ============================================================================

pub const Counter = struct {
    value: u64 = 0,
    
    pub fn increment(self: *Counter) void {
        self.value += 1;
    }
    
    pub fn add(self: *Counter, amount: u64) void {
        self.value += amount;
    }
    
    pub fn reset(self: *Counter) void {
        self.value = 0;
    }
    
    pub fn get(self: *const Counter) u64 {
        return self.value;
    }
};

// ============================================================================
// Operator Metrics
// ============================================================================

pub const OperatorMetrics = struct {
    allocator: std.mem.Allocator = undefined,
    name: []const u8,
    timer: Timer = .{},
    rows_input: Counter = .{},
    rows_output: Counter = .{},
    memory: MemoryTracker = .{},
    children: std.ArrayList(*OperatorMetrics),
    
    pub fn init(_: std.mem.Allocator, name: []const u8) OperatorMetrics {
        return .{
            .name = name,
            .children = .{},
        };
    }
    
    pub fn deinit(self: *OperatorMetrics) void {
        self.children.deinit(self.allocator);
    }
    
    pub fn addChild(self: *OperatorMetrics, child: *OperatorMetrics) !void {
        try self.children.append(self.allocator, child);
    }
    
    pub fn getStats(self: *const OperatorMetrics) OperatorStats {
        return .{
            .name = self.name,
            .time_ms = self.timer.elapsedMillis(),
            .rows_input = self.rows_input.get(),
            .rows_output = self.rows_output.get(),
            .memory_peak = self.memory.peak_usage,
        };
    }
};

pub const OperatorStats = struct {
    name: []const u8,
    time_ms: u64,
    rows_input: u64,
    rows_output: u64,
    memory_peak: usize,
};

// ============================================================================
// Query Profiler
// ============================================================================

pub const QueryProfiler = struct {
    allocator: std.mem.Allocator,
    enabled: bool = true,
    
    // Timers
    parse_timer: Timer = .{},
    bind_timer: Timer = .{},
    plan_timer: Timer = .{},
    optimize_timer: Timer = .{},
    execute_timer: Timer = .{},
    total_timer: Timer = .{},
    
    // Counters
    rows_returned: Counter = .{},
    
    // Memory
    memory: MemoryTracker = .{},
    
    // Operators
    operators: std.ArrayList(OperatorMetrics),
    
    pub fn init(allocator: std.mem.Allocator) QueryProfiler {
        return .{
            .allocator = allocator,
            .operators = .{},
        };
    }
    
    pub fn deinit(self: *QueryProfiler) void {
        for (self.operators.items) |*op| {
            op.deinit();
        }
        self.operators.deinit(self.allocator);
    }
    
    pub fn startTotal(self: *QueryProfiler) void {
        if (self.enabled) self.total_timer.start();
    }
    
    pub fn stopTotal(self: *QueryProfiler) void {
        if (self.enabled) self.total_timer.stop();
    }
    
    pub fn startParse(self: *QueryProfiler) void {
        if (self.enabled) self.parse_timer.start();
    }
    
    pub fn stopParse(self: *QueryProfiler) void {
        if (self.enabled) self.parse_timer.stop();
    }
    
    pub fn startBind(self: *QueryProfiler) void {
        if (self.enabled) self.bind_timer.start();
    }
    
    pub fn stopBind(self: *QueryProfiler) void {
        if (self.enabled) self.bind_timer.stop();
    }
    
    pub fn startPlan(self: *QueryProfiler) void {
        if (self.enabled) self.plan_timer.start();
    }
    
    pub fn stopPlan(self: *QueryProfiler) void {
        if (self.enabled) self.plan_timer.stop();
    }
    
    pub fn startOptimize(self: *QueryProfiler) void {
        if (self.enabled) self.optimize_timer.start();
    }
    
    pub fn stopOptimize(self: *QueryProfiler) void {
        if (self.enabled) self.optimize_timer.stop();
    }
    
    pub fn startExecute(self: *QueryProfiler) void {
        if (self.enabled) self.execute_timer.start();
    }
    
    pub fn stopExecute(self: *QueryProfiler) void {
        if (self.enabled) self.execute_timer.stop();
    }
    
    pub fn addOperator(self: *QueryProfiler, name: []const u8) !*OperatorMetrics {
        const op = OperatorMetrics.init(self.allocator, name);
        try self.operators.append(self.allocator, op);
        return &self.operators.items[self.operators.items.len - 1];
    }
    
    pub fn getSummary(self: *const QueryProfiler) ProfileSummary {
        return .{
            .total_ms = self.total_timer.elapsedMillis(),
            .parse_ms = self.parse_timer.elapsedMillis(),
            .bind_ms = self.bind_timer.elapsedMillis(),
            .plan_ms = self.plan_timer.elapsedMillis(),
            .optimize_ms = self.optimize_timer.elapsedMillis(),
            .execute_ms = self.execute_timer.elapsedMillis(),
            .rows_returned = self.rows_returned.get(),
            .memory_peak = self.memory.peak_usage,
            .operator_count = self.operators.items.len,
        };
    }
    
    pub fn reset(self: *QueryProfiler) void {
        self.parse_timer.reset();
        self.bind_timer.reset();
        self.plan_timer.reset();
        self.optimize_timer.reset();
        self.execute_timer.reset();
        self.total_timer.reset();
        self.rows_returned.reset();
        self.memory.reset();
        
        for (self.operators.items) |*op| {
            op.deinit();
        }
        self.operators.clearRetainingCapacity();
    }
};

pub const ProfileSummary = struct {
    total_ms: u64,
    parse_ms: u64,
    bind_ms: u64,
    plan_ms: u64,
    optimize_ms: u64,
    execute_ms: u64,
    rows_returned: u64,
    memory_peak: usize,
    operator_count: usize,
};

// ============================================================================
// Tests
// ============================================================================

test "timer basic" {
    var timer = Timer{};
    
    timer.start();
    std.Thread.sleep(1_000_000);  // 1ms
    timer.stop();
    
    try std.testing.expect(timer.elapsedNanos() > 0);
    try std.testing.expect(timer.elapsedMicros() > 0);
}

test "timer accumulated" {
    var timer = Timer{};
    
    timer.start();
    std.Thread.sleep(500_000);  // 0.5ms
    timer.stop();
    
    timer.start();
    std.Thread.sleep(500_000);  // 0.5ms
    timer.stop();
    
    try std.testing.expect(timer.elapsedMicros() >= 1000);
}

test "memory tracker" {
    var tracker = MemoryTracker{};
    
    try tracker.allocate(100);
    try std.testing.expectEqual(@as(usize, 100), tracker.current_usage);
    
    try tracker.allocate(50);
    try std.testing.expectEqual(@as(usize, 150), tracker.current_usage);
    try std.testing.expectEqual(@as(usize, 150), tracker.peak_usage);
    
    tracker.deallocate(100);
    try std.testing.expectEqual(@as(usize, 50), tracker.current_usage);
    try std.testing.expectEqual(@as(usize, 150), tracker.peak_usage);
}

test "memory tracker limit" {
    var tracker = MemoryTracker{};
    tracker.setLimit(100);
    
    try tracker.allocate(50);
    try std.testing.expectError(error.MemoryLimitExceeded, tracker.allocate(60));
}

test "counter" {
    var counter = Counter{};
    
    counter.increment();
    try std.testing.expectEqual(@as(u64, 1), counter.get());
    
    counter.add(10);
    try std.testing.expectEqual(@as(u64, 11), counter.get());
    
    counter.reset();
    try std.testing.expectEqual(@as(u64, 0), counter.get());
}

test "query profiler" {
    const allocator = std.testing.allocator;
    
    var profiler = QueryProfiler.init(allocator);
    defer profiler.deinit();
    
    profiler.startTotal();
    profiler.startParse();
    profiler.stopParse();
    profiler.startExecute();
    profiler.rows_returned.add(100);
    profiler.stopExecute();
    profiler.stopTotal();
    
    const summary = profiler.getSummary();
    try std.testing.expectEqual(@as(u64, 100), summary.rows_returned);
}
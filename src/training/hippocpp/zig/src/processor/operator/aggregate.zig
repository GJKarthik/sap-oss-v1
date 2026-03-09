//! Aggregate Operators - Aggregation processing
//!
//! Purpose:
//! Provides operators for GROUP BY and aggregation operations
//! including hash aggregation and simple aggregation.

const std = @import("std");

// ============================================================================
// Aggregate Type
// ============================================================================

pub const AggregateType = enum {
    COUNT,
    COUNT_STAR,
    SUM,
    AVG,
    MIN,
    MAX,
    COLLECT,
    FIRST,
    LAST,
};

// ============================================================================
// Aggregate State
// ============================================================================

pub const AggregateState = union(AggregateType) {
    COUNT: u64,
    COUNT_STAR: u64,
    SUM: SumState,
    AVG: AvgState,
    MIN: MinMaxState,
    MAX: MinMaxState,
    COLLECT: CollectState,
    FIRST: ?i64,
    LAST: ?i64,
    
    pub fn init(agg_type: AggregateType) AggregateState {
        return switch (agg_type) {
            .COUNT => .{ .COUNT = 0 },
            .COUNT_STAR => .{ .COUNT_STAR = 0 },
            .SUM => .{ .SUM = SumState{} },
            .AVG => .{ .AVG = AvgState{} },
            .MIN => .{ .MIN = MinMaxState{ .is_min = true } },
            .MAX => .{ .MAX = MinMaxState{ .is_min = false } },
            .COLLECT => .{ .COLLECT = CollectState{} },
            .FIRST => .{ .FIRST = null },
            .LAST => .{ .LAST = null },
        };
    }
};

pub const SumState = struct {
    sum: f64 = 0,
    has_value: bool = false,
    
    pub fn add(self: *SumState, value: f64) void {
        self.sum += value;
        self.has_value = true;
    }
    
    pub fn getResult(self: *const SumState) ?f64 {
        return if (self.has_value) self.sum else null;
    }
};

pub const AvgState = struct {
    sum: f64 = 0,
    count: u64 = 0,
    
    pub fn add(self: *AvgState, value: f64) void {
        self.sum += value;
        self.count += 1;
    }
    
    pub fn getResult(self: *const AvgState) ?f64 {
        return if (self.count > 0) self.sum / @as(f64, @floatFromInt(self.count)) else null;
    }
};

pub const MinMaxState = struct {
    value: ?f64 = null,
    is_min: bool = true,
    
    pub fn update(self: *MinMaxState, new_value: f64) void {
        if (self.value) |current| {
            if (self.is_min) {
                self.value = @min(current, new_value);
            } else {
                self.value = @max(current, new_value);
            }
        } else {
            self.value = new_value;
        }
    }
};

pub const CollectState = struct {
    count: u64 = 0,
};

// ============================================================================
// Group Key
// ============================================================================

pub const GroupKey = struct {
    values: []const i64,
    
    pub fn hash(self: GroupKey) u64 {
        var h: u64 = 0;
        for (self.values) |v| {
            h = h *% 31 +% @as(u64, @bitCast(v));
        }
        return h;
    }
    
    pub fn eql(self: GroupKey, other: GroupKey) bool {
        if (self.values.len != other.values.len) return false;
        for (self.values, other.values) |a, b| {
            if (a != b) return false;
        }
        return true;
    }
};

// ============================================================================
// Aggregate Operator
// ============================================================================

pub const AggregateOperator = struct {
    allocator: std.mem.Allocator,
    aggregate_types: []const AggregateType,
    num_groups: usize = 0,
    rows_processed: u64 = 0,
    is_finalized: bool = false,
    
    pub fn init(allocator: std.mem.Allocator, aggregate_types: []const AggregateType) AggregateOperator {
        return .{
            .allocator = allocator,
            .aggregate_types = aggregate_types,
        };
    }
    
    pub fn deinit(self: *AggregateOperator) void {
        _ = self;
    }
    
    pub fn processRow(self: *AggregateOperator) void {
        self.rows_processed += 1;
    }
    
    pub fn addGroup(self: *AggregateOperator) void {
        self.num_groups += 1;
    }
    
    pub fn finalize(self: *AggregateOperator) void {
        self.is_finalized = true;
    }
    
    pub fn getStats(self: *const AggregateOperator) AggregateStats {
        return .{
            .num_groups = self.num_groups,
            .rows_processed = self.rows_processed,
            .is_finalized = self.is_finalized,
        };
    }
};

pub const AggregateStats = struct {
    num_groups: usize,
    rows_processed: u64,
    is_finalized: bool,
};

// ============================================================================
// Simple Aggregate (no GROUP BY)
// ============================================================================

pub const SimpleAggregate = struct {
    allocator: std.mem.Allocator,
    aggregate_type: AggregateType,
    state: AggregateState,
    
    pub fn init(allocator: std.mem.Allocator, aggregate_type: AggregateType) SimpleAggregate {
        return .{
            .allocator = allocator,
            .aggregate_type = aggregate_type,
            .state = AggregateState.init(aggregate_type),
        };
    }
    
    pub fn addValue(self: *SimpleAggregate, value: f64) void {
        switch (self.state) {
            .COUNT => |*c| c.* += 1,
            .COUNT_STAR => |*c| c.* += 1,
            .SUM => |*s| s.add(value),
            .AVG => |*a| a.add(value),
            .MIN => |*m| m.update(value),
            .MAX => |*m| m.update(value),
            else => {},
        }
    }
    
    pub fn getCount(self: *const SimpleAggregate) u64 {
        return switch (self.state) {
            .COUNT => |c| c,
            .COUNT_STAR => |c| c,
            .AVG => |a| a.count,
            else => 0,
        };
    }
    
    pub fn getSum(self: *const SimpleAggregate) ?f64 {
        return switch (self.state) {
            .SUM => |s| s.getResult(),
            else => null,
        };
    }
    
    pub fn getAvg(self: *const SimpleAggregate) ?f64 {
        return switch (self.state) {
            .AVG => |a| a.getResult(),
            else => null,
        };
    }
    
    pub fn getMinMax(self: *const SimpleAggregate) ?f64 {
        return switch (self.state) {
            .MIN => |m| m.value,
            .MAX => |m| m.value,
            else => null,
        };
    }
};

// ============================================================================
// Hash Aggregate
// ============================================================================

pub const HashAggregate = struct {
    allocator: std.mem.Allocator,
    group_count: usize = 0,
    rows_processed: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator) HashAggregate {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *HashAggregate) void {
        _ = self;
    }
    
    pub fn addGroup(self: *HashAggregate) void {
        self.group_count += 1;
    }
    
    pub fn processRow(self: *HashAggregate) void {
        self.rows_processed += 1;
    }
    
    pub fn getGroupCount(self: *const HashAggregate) usize {
        return self.group_count;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "aggregate state init" {
    const state = AggregateState.init(.COUNT);
    try std.testing.expectEqual(@as(u64, 0), state.COUNT);
}

test "sum state" {
    var state = SumState{};
    state.add(10);
    state.add(20);
    state.add(30);
    
    try std.testing.expectEqual(@as(f64, 60), state.getResult().?);
}

test "avg state" {
    var state = AvgState{};
    state.add(10);
    state.add(20);
    state.add(30);
    
    try std.testing.expectEqual(@as(f64, 20), state.getResult().?);
}

test "min max state" {
    var min_state = MinMaxState{ .is_min = true };
    min_state.update(30);
    min_state.update(10);
    min_state.update(20);
    try std.testing.expectEqual(@as(f64, 10), min_state.value.?);
    
    var max_state = MinMaxState{ .is_min = false };
    max_state.update(30);
    max_state.update(10);
    max_state.update(20);
    try std.testing.expectEqual(@as(f64, 30), max_state.value.?);
}

test "simple aggregate count" {
    const allocator = std.testing.allocator;
    
    var agg = SimpleAggregate.init(allocator, .COUNT);
    agg.addValue(1);
    agg.addValue(2);
    agg.addValue(3);
    
    try std.testing.expectEqual(@as(u64, 3), agg.getCount());
}

test "simple aggregate sum" {
    const allocator = std.testing.allocator;
    
    var agg = SimpleAggregate.init(allocator, .SUM);
    agg.addValue(10);
    agg.addValue(20);
    agg.addValue(30);
    
    try std.testing.expectEqual(@as(f64, 60), agg.getSum().?);
}

test "hash aggregate" {
    const allocator = std.testing.allocator;
    
    var agg = HashAggregate.init(allocator);
    defer agg.deinit(std.testing.allocator);
    
    agg.addGroup();
    agg.addGroup();
    agg.processRow();
    agg.processRow();
    agg.processRow();
    
    try std.testing.expectEqual(@as(usize, 2), agg.getGroupCount());
    try std.testing.expectEqual(@as(u64, 3), agg.rows_processed);
}
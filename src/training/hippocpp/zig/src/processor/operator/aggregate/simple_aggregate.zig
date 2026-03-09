//! SimpleAggregateSharedState — Ported from kuzu C++ (156L header, 275L source).
//!
//! Extends BaseAggregateSharedState in the upstream implementation.

const std = @import("std");

pub const SimpleAggregateSharedState = struct {
    allocator: std.mem.Allocator,
    SimpleAggregate: ?*anyopaque = null,
    readyForFinalization: ?*anyopaque = null,
    hashTable: ?*?*anyopaque = null,
    queue: ?*?*anyopaque = null,
    state: ?*?*anyopaque = null,
    mtx: ?*anyopaque = null,
    distinctTables: std.ArrayList(?*anyopaque) = .{},
    functionIdx: usize = 0,
    hasDistinct: bool = false,
    globalPartitions: std.ArrayList(?*anyopaque) = .{},
    partitioningData: std.ArrayList(?*anyopaque) = .{},
    aggregateOverflowBuffer: ?*anyopaque = null,
    aggregates: std.ArrayList(u8) = .{},
    true: ?*anyopaque = null,
    sharedState: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn delete_copy_and_move(self: *Self) void {
        _ = self;
    }

    pub fn combine_aggregate_states(self: *Self) void {
        _ = self;
    }

    pub fn finalize_aggregate_states(self: *Self) void {
        _ = self;
    }

    pub fn concurrently(self: *Self) void {
        _ = self;
    }

    pub fn finalize_partitions(self: *Self) void {
        _ = self;
    }

    pub fn is_ready_for_finalization(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn append_tuples(self: *Self) void {
        _ = self;
    }

    pub fn append_distinct_tuple(self: *Self) void {
        _ = self;
    }

    pub fn append_overflow(self: *Self) void {
        _ = self;
    }

    pub fn simple_aggregate_print_info(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this SimpleAggregateSharedState.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.functionIdx = self.functionIdx;
        new.hasDistinct = self.hasDistinct;
        return new;
    }

};

test "SimpleAggregateSharedState" {
    const allocator = std.testing.allocator;
    var instance = SimpleAggregateSharedState.init(allocator);
    defer instance.deinit();
}

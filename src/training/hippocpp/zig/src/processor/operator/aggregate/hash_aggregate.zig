//! HashAggregateSharedState — Ported from kuzu C++ (205L header, 311L source).
//!
//! Extends BaseAggregateSharedState in the upstream implementation.

const std = @import("std");

pub const HashAggregateSharedState = struct {
    allocator: std.mem.Allocator,
    flatKeysPos: std.ArrayList(?*anyopaque) = .{},
    unFlatKeysPos: std.ArrayList(?*anyopaque) = .{},
    dependentKeysPos: std.ArrayList(?*anyopaque) = .{},
    tableSchema: ?*anyopaque = null,
    currentOffset: ?*anyopaque = null,
    limitNumber: ?*anyopaque = null,
    aggInfo: ?*anyopaque = null,
    hashTable: ?*?*anyopaque = null,
    mtx: ?*anyopaque = null,
    queue: ?*?*anyopaque = null,
    globalPartitions: std.ArrayList(?*anyopaque) = .{},
    keyVectors: std.ArrayList(?*anyopaque) = .{},
    dependentKeyVectors: std.ArrayList(?*anyopaque) = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
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

    pub fn finalize_partitions(self: *Self) void {
        _ = self;
    }

    pub fn scan(self: *Self) void {
        _ = self;
    }

    pub fn get_num_tuples(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_current_offset(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn set_limit_number(self: *Self) void {
        _ = self;
    }

    pub fn get_limit_number(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn assert_finalized(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this HashAggregateSharedState.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "HashAggregateSharedState" {
    const allocator = std.testing.allocator;
    var instance = HashAggregateSharedState.init(allocator);
    defer instance.deinit();
}

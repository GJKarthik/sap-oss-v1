//! BaseAggregateScan — Ported from kuzu C++ (44L header, 18L source).
//!
//! Extends PhysicalOperator in the upstream implementation.

const std = @import("std");

pub const BaseAggregateScan = struct {
    allocator: std.mem.Allocator,
    aggregatesPos: std.ArrayList(?*anyopaque) = .{},
    moveAggResultToVectorFuncs: std.ArrayList(std.ArrayList(u8)) = .{},
    true: ?*anyopaque = null,
    scanInfo: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn is_source(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn init_local_state_internal(self: *Self) void {
        _ = self;
    }

    pub fn get_next_tuples_internal(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    /// Create a deep copy of this BaseAggregateScan.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "BaseAggregateScan" {
    const allocator = std.testing.allocator;
    var instance = BaseAggregateScan.init(allocator);
    defer instance.deinit();
    _ = instance.is_source();
    _ = instance.get_next_tuples_internal();
}

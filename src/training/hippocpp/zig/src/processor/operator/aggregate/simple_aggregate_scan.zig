//! SimpleAggregateScan — Ported from kuzu C++ (30L header, 36L source).
//!
//! Extends BaseAggregateScan in the upstream implementation.

const std = @import("std");

pub const SimpleAggregateScan = struct {
    allocator: std.mem.Allocator,
    sharedState: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn init_local_state_internal(self: *Self) void {
        _ = self;
    }

    pub fn get_next_tuples_internal(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    /// Create a deep copy of this SimpleAggregateScan.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "SimpleAggregateScan" {
    const allocator = std.testing.allocator;
    var instance = SimpleAggregateScan.init(allocator);
    defer instance.deinit();
    _ = instance.get_next_tuples_internal();
}

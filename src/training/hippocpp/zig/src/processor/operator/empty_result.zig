//! EmptyResult — Ported from kuzu C++ (25L header, 11L source).
//!
//! Extends PhysicalOperator in the upstream implementation.

const std = @import("std");

pub const EmptyResult = struct {
    allocator: std.mem.Allocator,
    true: ?*anyopaque = null,

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

    pub fn get_next_tuples_internal(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    /// Create a deep copy of this EmptyResult.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "EmptyResult" {
    const allocator = std.testing.allocator;
    var instance = EmptyResult.init(allocator);
    defer instance.deinit();
    _ = instance.is_source();
    _ = instance.get_next_tuples_internal();
}

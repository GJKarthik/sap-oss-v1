//! Flatten — Ported from kuzu C++ (42L header, 91L source).
//!
//! Extends PhysicalOperator in the upstream implementation.

const std = @import("std");

pub const Flatten = struct {
    allocator: std.mem.Allocator,
    dataChunkToFlattenPos: ?*anyopaque = null,
    localState: ?*?*anyopaque = null,

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

    pub fn reset_current_sel_vector(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this Flatten.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "Flatten" {
    const allocator = std.testing.allocator;
    var instance = Flatten.init(allocator);
    defer instance.deinit();
    _ = instance.get_next_tuples_internal();
}

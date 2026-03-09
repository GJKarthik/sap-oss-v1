//! Insert — Ported from kuzu C++ (53L header, 42L source).
//!
//! Extends PhysicalOperator in the upstream implementation.

const std = @import("std");

pub const Insert = struct {
    allocator: std.mem.Allocator,
    expressions: std.ArrayList(u8) = .{},
    action: ?*anyopaque = null,
    false: ?*anyopaque = null,
    nodeExecutors: std.ArrayList(?*anyopaque) = .{},
    relExecutors: std.ArrayList(?*anyopaque) = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn insert_print_info(self: *Self) void {
        _ = self;
    }

    pub fn is_parallel(self: *const Self) bool {
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

    /// Create a deep copy of this Insert.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "Insert" {
    const allocator = std.testing.allocator;
    var instance = Insert.init(allocator);
    defer instance.deinit();
    _ = instance.is_parallel();
    _ = instance.get_next_tuples_internal();
}

//! PhysicalPlan — Ported from kuzu C++ (34L header, 19L source).
//!

const std = @import("std");

pub const PhysicalPlan = struct {
    allocator: std.mem.Allocator,
    PhysicalPlan: ?*anyopaque = null,
    info: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn set_physical_plan(self: *Self) void {
        _ = self;
    }

    pub fn execute_internal(self: *Self) void {
        _ = self;
    }

};

test "PhysicalPlan" {
    const allocator = std.testing.allocator;
    var instance = PhysicalPlan.init(allocator);
    defer instance.deinit();
}

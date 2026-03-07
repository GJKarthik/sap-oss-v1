//! PhysicalPlan
const std = @import("std");

pub const PhysicalPlan = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) PhysicalPlan { return .{ .allocator = allocator }; }
    pub fn deinit(self: *PhysicalPlan) void { _ = self; }
};

test "PhysicalPlan" {
    const allocator = std.testing.allocator;
    var instance = PhysicalPlan.init(allocator);
    defer instance.deinit();
}

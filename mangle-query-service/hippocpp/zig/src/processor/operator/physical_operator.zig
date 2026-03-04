//! PhysicalOperator
const std = @import("std");

pub const PhysicalOperator = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) PhysicalOperator { return .{ .allocator = allocator }; }
    pub fn deinit(self: *PhysicalOperator) void { _ = self; }
};

test "PhysicalOperator" {
    const allocator = std.testing.allocator;
    var instance = PhysicalOperator.init(allocator);
    defer instance.deinit();
}

//! ExpressionPlanner
const std = @import("std");

pub const ExpressionPlanner = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ExpressionPlanner { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ExpressionPlanner) void { _ = self; }
};

test "ExpressionPlanner" {
    const allocator = std.testing.allocator;
    var instance = ExpressionPlanner.init(allocator);
    defer instance.deinit();
}

//! ExpressionSimplification
const std = @import("std");

pub const ExpressionSimplification = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ExpressionSimplification { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ExpressionSimplification) void { _ = self; }
};

test "ExpressionSimplification" {
    const allocator = std.testing.allocator;
    var instance = ExpressionSimplification.init(allocator);
    defer instance.deinit();
}

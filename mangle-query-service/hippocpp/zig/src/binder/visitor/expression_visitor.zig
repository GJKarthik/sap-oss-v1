//! ExpressionVisitorBinder
const std = @import("std");

pub const ExpressionVisitorBinder = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ExpressionVisitorBinder { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ExpressionVisitorBinder) void { _ = self; }
};

test "ExpressionVisitorBinder" {
    const allocator = std.testing.allocator;
    var instance = ExpressionVisitorBinder.init(allocator);
    defer instance.deinit();
}

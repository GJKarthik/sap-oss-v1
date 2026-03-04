//! ExpressionBinder
const std = @import("std");

pub const ExpressionBinder = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ExpressionBinder { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ExpressionBinder) void { _ = self; }
};

test "ExpressionBinder" {
    const allocator = std.testing.allocator;
    var instance = ExpressionBinder.init(allocator);
    defer instance.deinit();
}

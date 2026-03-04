//! BoundNodeExpression
const std = @import("std");

pub const BoundNodeExpression = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BoundNodeExpression { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BoundNodeExpression) void { _ = self; }
};

test "BoundNodeExpression" {
    const allocator = std.testing.allocator;
    var instance = BoundNodeExpression.init(allocator);
    defer instance.deinit();
}

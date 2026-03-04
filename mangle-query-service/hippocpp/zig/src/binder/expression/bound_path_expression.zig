//! BoundPathExpression
const std = @import("std");

pub const BoundPathExpression = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BoundPathExpression { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BoundPathExpression) void { _ = self; }
};

test "BoundPathExpression" {
    const allocator = std.testing.allocator;
    var instance = BoundPathExpression.init(allocator);
    defer instance.deinit();
}

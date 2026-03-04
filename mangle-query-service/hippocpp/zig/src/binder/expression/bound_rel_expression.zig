//! BoundRelExpression
const std = @import("std");

pub const BoundRelExpression = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BoundRelExpression { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BoundRelExpression) void { _ = self; }
};

test "BoundRelExpression" {
    const allocator = std.testing.allocator;
    var instance = BoundRelExpression.init(allocator);
    defer instance.deinit();
}

//! BoundFunctionExpr
const std = @import("std");

pub const BoundFunctionExpr = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BoundFunctionExpr { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BoundFunctionExpr) void { _ = self; }
};

test "BoundFunctionExpr" {
    const allocator = std.testing.allocator;
    var instance = BoundFunctionExpr.init(allocator);
    defer instance.deinit();
}

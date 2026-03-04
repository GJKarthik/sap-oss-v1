//! BoundAggregateExpr
const std = @import("std");

pub const BoundAggregateExpr = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BoundAggregateExpr { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BoundAggregateExpr) void { _ = self; }
};

test "BoundAggregateExpr" {
    const allocator = std.testing.allocator;
    var instance = BoundAggregateExpr.init(allocator);
    defer instance.deinit();
}

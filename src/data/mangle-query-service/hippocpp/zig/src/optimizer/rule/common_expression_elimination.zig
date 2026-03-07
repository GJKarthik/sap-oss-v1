//! CommonExpressionElimination
const std = @import("std");

pub const CommonExpressionElimination = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) CommonExpressionElimination { return .{ .allocator = allocator }; }
    pub fn deinit(self: *CommonExpressionElimination) void { _ = self; }
};

test "CommonExpressionElimination" {
    const allocator = std.testing.allocator;
    var instance = CommonExpressionElimination.init(allocator);
    defer instance.deinit();
}

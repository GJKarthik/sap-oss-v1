//! ExpressionRewriter
const std = @import("std");

pub const ExpressionRewriter = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ExpressionRewriter { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ExpressionRewriter) void { _ = self; }
};

test "ExpressionRewriter" {
    const allocator = std.testing.allocator;
    var instance = ExpressionRewriter.init(allocator);
    defer instance.deinit();
}

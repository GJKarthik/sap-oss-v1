//! ParsedLambdaExpr
const std = @import("std");

pub const ParsedLambdaExpr = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ParsedLambdaExpr { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ParsedLambdaExpr) void { _ = self; }
};

test "ParsedLambdaExpr" {
    const allocator = std.testing.allocator;
    var instance = ParsedLambdaExpr.init(allocator);
    defer instance.deinit();
}

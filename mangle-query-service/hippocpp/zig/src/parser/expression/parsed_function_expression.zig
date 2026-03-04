//! ParsedFunctionExpr
const std = @import("std");

pub const ParsedFunctionExpr = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ParsedFunctionExpr { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ParsedFunctionExpr) void { _ = self; }
};

test "ParsedFunctionExpr" {
    const allocator = std.testing.allocator;
    var instance = ParsedFunctionExpr.init(allocator);
    defer instance.deinit();
}

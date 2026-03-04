//! ParsedLiteralExpr
const std = @import("std");

pub const ParsedLiteralExpr = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ParsedLiteralExpr { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ParsedLiteralExpr) void { _ = self; }
};

test "ParsedLiteralExpr" {
    const allocator = std.testing.allocator;
    var instance = ParsedLiteralExpr.init(allocator);
    defer instance.deinit();
}

//! ParsedParameterExpr
const std = @import("std");

pub const ParsedParameterExpr = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ParsedParameterExpr { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ParsedParameterExpr) void { _ = self; }
};

test "ParsedParameterExpr" {
    const allocator = std.testing.allocator;
    var instance = ParsedParameterExpr.init(allocator);
    defer instance.deinit();
}

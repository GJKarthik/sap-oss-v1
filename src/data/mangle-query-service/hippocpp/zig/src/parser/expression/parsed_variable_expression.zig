//! ParsedVariableExpr
const std = @import("std");

pub const ParsedVariableExpr = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ParsedVariableExpr { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ParsedVariableExpr) void { _ = self; }
};

test "ParsedVariableExpr" {
    const allocator = std.testing.allocator;
    var instance = ParsedVariableExpr.init(allocator);
    defer instance.deinit();
}

//! ParsedCaseExpr
const std = @import("std");

pub const ParsedCaseExpr = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ParsedCaseExpr { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ParsedCaseExpr) void { _ = self; }
};

test "ParsedCaseExpr" {
    const allocator = std.testing.allocator;
    var instance = ParsedCaseExpr.init(allocator);
    defer instance.deinit();
}

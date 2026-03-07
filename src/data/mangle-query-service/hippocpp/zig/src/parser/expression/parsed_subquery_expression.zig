//! ParsedSubqueryExpr
const std = @import("std");

pub const ParsedSubqueryExpr = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ParsedSubqueryExpr { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ParsedSubqueryExpr) void { _ = self; }
};

test "ParsedSubqueryExpr" {
    const allocator = std.testing.allocator;
    var instance = ParsedSubqueryExpr.init(allocator);
    defer instance.deinit();
}

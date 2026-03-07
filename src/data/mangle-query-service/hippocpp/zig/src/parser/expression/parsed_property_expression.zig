//! ParsedPropertyExpr
const std = @import("std");

pub const ParsedPropertyExpr = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ParsedPropertyExpr { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ParsedPropertyExpr) void { _ = self; }
};

test "ParsedPropertyExpr" {
    const allocator = std.testing.allocator;
    var instance = ParsedPropertyExpr.init(allocator);
    defer instance.deinit();
}

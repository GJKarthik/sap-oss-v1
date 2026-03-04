//! ParsedListExpr
const std = @import("std");

pub const ParsedListExpr = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ParsedListExpr { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ParsedListExpr) void { _ = self; }
};

test "ParsedListExpr" {
    const allocator = std.testing.allocator;
    var instance = ParsedListExpr.init(allocator);
    defer instance.deinit();
}

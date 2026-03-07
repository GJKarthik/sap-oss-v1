//! ParsedExpression
const std = @import("std");

pub const ParsedExpression = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ParsedExpression { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ParsedExpression) void { _ = self; }
};

test "ParsedExpression" {
    const allocator = std.testing.allocator;
    var instance = ParsedExpression.init(allocator);
    defer instance.deinit();
}

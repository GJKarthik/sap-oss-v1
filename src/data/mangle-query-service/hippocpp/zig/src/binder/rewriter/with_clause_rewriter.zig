//! WithClauseRewriter
const std = @import("std");

pub const WithClauseRewriter = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) WithClauseRewriter { return .{ .allocator = allocator }; }
    pub fn deinit(self: *WithClauseRewriter) void { _ = self; }
};

test "WithClauseRewriter" {
    const allocator = std.testing.allocator;
    var instance = WithClauseRewriter.init(allocator);
    defer instance.deinit();
}

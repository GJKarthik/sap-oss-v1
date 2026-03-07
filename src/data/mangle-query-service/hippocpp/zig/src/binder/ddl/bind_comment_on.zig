//! BindCommentOn
const std = @import("std");

pub const BindCommentOn = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BindCommentOn { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BindCommentOn) void { _ = self; }
};

test "BindCommentOn" {
    const allocator = std.testing.allocator;
    var instance = BindCommentOn.init(allocator);
    defer instance.deinit();
}

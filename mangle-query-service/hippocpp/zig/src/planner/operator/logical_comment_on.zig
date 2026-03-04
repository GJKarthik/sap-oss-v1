//! LogicalCommentOn
const std = @import("std");

pub const LogicalCommentOn = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalCommentOn { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalCommentOn) void { _ = self; }
};

test "LogicalCommentOn" {
    const allocator = std.testing.allocator;
    var instance = LogicalCommentOn.init(allocator);
    defer instance.deinit();
}

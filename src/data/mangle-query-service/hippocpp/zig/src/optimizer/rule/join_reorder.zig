//! JoinReorder
const std = @import("std");

pub const JoinReorder = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) JoinReorder { return .{ .allocator = allocator }; }
    pub fn deinit(self: *JoinReorder) void { _ = self; }
};

test "JoinReorder" {
    const allocator = std.testing.allocator;
    var instance = JoinReorder.init(allocator);
    defer instance.deinit();
}

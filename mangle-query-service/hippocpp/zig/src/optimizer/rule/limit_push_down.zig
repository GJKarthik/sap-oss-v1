//! LimitPushDown
const std = @import("std");

pub const LimitPushDown = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LimitPushDown { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LimitPushDown) void { _ = self; }
};

test "LimitPushDown" {
    const allocator = std.testing.allocator;
    var instance = LimitPushDown.init(allocator);
    defer instance.deinit();
}

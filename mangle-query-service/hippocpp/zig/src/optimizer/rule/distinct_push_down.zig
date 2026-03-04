//! DistinctPushDown
const std = @import("std");

pub const DistinctPushDown = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) DistinctPushDown { return .{ .allocator = allocator }; }
    pub fn deinit(self: *DistinctPushDown) void { _ = self; }
};

test "DistinctPushDown" {
    const allocator = std.testing.allocator;
    var instance = DistinctPushDown.init(allocator);
    defer instance.deinit();
}

//! AggregatePushDown
const std = @import("std");

pub const AggregatePushDown = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) AggregatePushDown { return .{ .allocator = allocator }; }
    pub fn deinit(self: *AggregatePushDown) void { _ = self; }
};

test "AggregatePushDown" {
    const allocator = std.testing.allocator;
    var instance = AggregatePushDown.init(allocator);
    defer instance.deinit();
}

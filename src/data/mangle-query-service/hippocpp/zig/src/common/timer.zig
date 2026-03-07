//! Timer
const std = @import("std");

pub const Timer = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Timer { return .{ .allocator = allocator }; }
    pub fn deinit(self: *Timer) void { _ = self; }
};

test "Timer" {
    const allocator = std.testing.allocator;
    var instance = Timer.init(allocator);
    defer instance.deinit();
}

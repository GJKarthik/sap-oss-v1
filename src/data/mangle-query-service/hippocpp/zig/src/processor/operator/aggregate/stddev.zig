//! StdDev
const std = @import("std");

pub const StdDev = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) StdDev { return .{ .allocator = allocator }; }
    pub fn deinit(self: *StdDev) void { _ = self; }
};

test "StdDev" {
    const allocator = std.testing.allocator;
    var instance = StdDev.init(allocator);
    defer instance.deinit();
}

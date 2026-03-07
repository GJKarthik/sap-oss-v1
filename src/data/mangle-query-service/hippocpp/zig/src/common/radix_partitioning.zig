//! RadixPartitioning
const std = @import("std");

pub const RadixPartitioning = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) RadixPartitioning { return .{ .allocator = allocator }; }
    pub fn deinit(self: *RadixPartitioning) void { _ = self; }
};

test "RadixPartitioning" {
    const allocator = std.testing.allocator;
    var instance = RadixPartitioning.init(allocator);
    defer instance.deinit();
}

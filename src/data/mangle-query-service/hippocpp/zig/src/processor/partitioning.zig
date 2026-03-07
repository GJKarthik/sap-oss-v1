//! Partitioning
const std = @import("std");

pub const Partitioning = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Partitioning { return .{ .allocator = allocator }; }
    pub fn deinit(self: *Partitioning) void { _ = self; }
};

test "Partitioning" {
    const allocator = std.testing.allocator;
    var instance = Partitioning.init(allocator);
    defer instance.deinit();
}

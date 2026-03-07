//! Random
const std = @import("std");

pub const Random = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Random { return .{ .allocator = allocator }; }
    pub fn deinit(self: *Random) void { _ = self; }
};

test "Random" {
    const allocator = std.testing.allocator;
    var instance = Random.init(allocator);
    defer instance.deinit();
}

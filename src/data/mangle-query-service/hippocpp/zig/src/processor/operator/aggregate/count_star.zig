//! CountStar
const std = @import("std");

pub const CountStar = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) CountStar { return .{ .allocator = allocator }; }
    pub fn deinit(self: *CountStar) void { _ = self; }
};

test "CountStar" {
    const allocator = std.testing.allocator;
    var instance = CountStar.init(allocator);
    defer instance.deinit();
}

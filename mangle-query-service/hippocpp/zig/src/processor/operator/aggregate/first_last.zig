//! FirstLast
const std = @import("std");

pub const FirstLast = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) FirstLast { return .{ .allocator = allocator }; }
    pub fn deinit(self: *FirstLast) void { _ = self; }
};

test "FirstLast" {
    const allocator = std.testing.allocator;
    var instance = FirstLast.init(allocator);
    defer instance.deinit();
}

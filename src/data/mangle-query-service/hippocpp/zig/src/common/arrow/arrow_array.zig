//! ArrowArray
const std = @import("std");

pub const ArrowArray = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ArrowArray { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ArrowArray) void { _ = self; }
};

test "ArrowArray" {
    const allocator = std.testing.allocator;
    var instance = ArrowArray.init(allocator);
    defer instance.deinit();
}

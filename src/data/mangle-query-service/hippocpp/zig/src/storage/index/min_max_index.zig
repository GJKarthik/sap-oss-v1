//! MinMaxIndex
const std = @import("std");

pub const MinMaxIndex = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) MinMaxIndex { return .{ .allocator = allocator }; }
    pub fn deinit(self: *MinMaxIndex) void { _ = self; }
};

test "MinMaxIndex" {
    const allocator = std.testing.allocator;
    var instance = MinMaxIndex.init(allocator);
    defer instance.deinit();
}

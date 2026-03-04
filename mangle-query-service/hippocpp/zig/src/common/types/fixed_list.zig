//! FixedList
const std = @import("std");

pub const FixedList = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) FixedList { return .{ .allocator = allocator }; }
    pub fn deinit(self: *FixedList) void { _ = self; }
};

test "FixedList" {
    const allocator = std.testing.allocator;
    var instance = FixedList.init(allocator);
    defer instance.deinit();
}

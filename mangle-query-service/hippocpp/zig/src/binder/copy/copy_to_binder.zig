//! CopyToBinder
const std = @import("std");

pub const CopyToBinder = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) CopyToBinder { return .{ .allocator = allocator }; }
    pub fn deinit(self: *CopyToBinder) void { _ = self; }
};

test "CopyToBinder" {
    const allocator = std.testing.allocator;
    var instance = CopyToBinder.init(allocator);
    defer instance.deinit();
}

//! CopyFromBinder
const std = @import("std");

pub const CopyFromBinder = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) CopyFromBinder { return .{ .allocator = allocator }; }
    pub fn deinit(self: *CopyFromBinder) void { _ = self; }
};

test "CopyFromBinder" {
    const allocator = std.testing.allocator;
    var instance = CopyFromBinder.init(allocator);
    defer instance.deinit();
}

//! RowLock
const std = @import("std");

pub const RowLock = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) RowLock { return .{ .allocator = allocator }; }
    pub fn deinit(self: *RowLock) void { _ = self; }
};

test "RowLock" {
    const allocator = std.testing.allocator;
    var instance = RowLock.init(allocator);
    defer instance.deinit();
}

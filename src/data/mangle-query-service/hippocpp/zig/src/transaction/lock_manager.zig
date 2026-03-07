//! LockManager
const std = @import("std");

pub const LockManager = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LockManager { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LockManager) void { _ = self; }
};

test "LockManager" {
    const allocator = std.testing.allocator;
    var instance = LockManager.init(allocator);
    defer instance.deinit();
}

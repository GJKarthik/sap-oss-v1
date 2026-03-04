//! OffsetManager
const std = @import("std");

pub const OffsetManager = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) OffsetManager { return .{ .allocator = allocator }; }
    pub fn deinit(self: *OffsetManager) void { _ = self; }
};

test "OffsetManager" {
    const allocator = std.testing.allocator;
    var instance = OffsetManager.init(allocator);
    defer instance.deinit();
}

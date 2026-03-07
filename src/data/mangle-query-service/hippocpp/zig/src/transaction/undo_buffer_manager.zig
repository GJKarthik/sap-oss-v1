//! UndoBufferManager
const std = @import("std");

pub const UndoBufferManager = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) UndoBufferManager { return .{ .allocator = allocator }; }
    pub fn deinit(self: *UndoBufferManager) void { _ = self; }
};

test "UndoBufferManager" {
    const allocator = std.testing.allocator;
    var instance = UndoBufferManager.init(allocator);
    defer instance.deinit();
}

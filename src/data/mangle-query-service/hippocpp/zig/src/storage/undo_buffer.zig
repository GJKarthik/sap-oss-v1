//! UndoBuffer
const std = @import("std");

pub const UndoBuffer = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) UndoBuffer { return .{ .allocator = allocator }; }
    pub fn deinit(self: *UndoBuffer) void { _ = self; }
};

test "UndoBuffer" {
    const allocator = std.testing.allocator;
    var instance = UndoBuffer.init(allocator);
    defer instance.deinit();
}

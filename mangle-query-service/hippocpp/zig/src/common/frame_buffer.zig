//! FrameBuffer
const std = @import("std");

pub const FrameBuffer = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) FrameBuffer { return .{ .allocator = allocator }; }
    pub fn deinit(self: *FrameBuffer) void { _ = self; }
};

test "FrameBuffer" {
    const allocator = std.testing.allocator;
    var instance = FrameBuffer.init(allocator);
    defer instance.deinit();
}

//! BufferFrame
const std = @import("std");

pub const BufferFrame = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BufferFrame {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BufferFrame) void {
        _ = self;
    }
};

test "BufferFrame" {
    const allocator = std.testing.allocator;
    var instance = BufferFrame.init(allocator);
    defer instance.deinit();
}

//! InMemOverflowBuffer
const std = @import("std");

pub const InMemOverflowBuffer = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) InMemOverflowBuffer {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *InMemOverflowBuffer) void {
        _ = self;
    }
};

test "InMemOverflowBuffer" {
    const allocator = std.testing.allocator;
    var instance = InMemOverflowBuffer.init(allocator);
    defer instance.deinit();
}

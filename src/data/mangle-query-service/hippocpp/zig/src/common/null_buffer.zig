//! NullBuffer
const std = @import("std");

pub const NullBuffer = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) NullBuffer {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *NullBuffer) void {
        _ = self;
    }
};

test "NullBuffer" {
    const allocator = std.testing.allocator;
    var instance = NullBuffer.init(allocator);
    defer instance.deinit();
}

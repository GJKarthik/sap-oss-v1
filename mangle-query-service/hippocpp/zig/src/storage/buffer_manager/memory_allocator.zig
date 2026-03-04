//! MemoryAllocator
const std = @import("std");

pub const MemoryAllocator = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) MemoryAllocator {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *MemoryAllocator) void {
        _ = self;
    }
};

test "MemoryAllocator" {
    const allocator = std.testing.allocator;
    var instance = MemoryAllocator.init(allocator);
    defer instance.deinit();
}

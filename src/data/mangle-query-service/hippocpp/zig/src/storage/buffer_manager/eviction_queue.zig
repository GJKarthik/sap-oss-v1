//! EvictionQueue
const std = @import("std");

pub const EvictionQueue = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) EvictionQueue {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *EvictionQueue) void {
        _ = self;
    }
};

test "EvictionQueue" {
    const allocator = std.testing.allocator;
    var instance = EvictionQueue.init(allocator);
    defer instance.deinit();
}

//! ChunkState
const std = @import("std");

pub const ChunkState = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ChunkState {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ChunkState) void {
        _ = self;
    }
};

test "ChunkState" {
    const allocator = std.testing.allocator;
    var instance = ChunkState.init(allocator);
    defer instance.deinit();
}

//! ChunkMetadata
const std = @import("std");

pub const ChunkMetadata = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ChunkMetadata { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ChunkMetadata) void { _ = self; }
};

test "ChunkMetadata" {
    const allocator = std.testing.allocator;
    var instance = ChunkMetadata.init(allocator);
    defer instance.deinit();
}

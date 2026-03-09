//! MemoryAllocator — graph database engine module.
//!

const std = @import("std");

pub const MemoryAllocator = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }



};

test "MemoryAllocator" {
    const allocator = std.testing.allocator;
    var instance = MemoryAllocator.init(allocator);
    defer instance.deinit();
}

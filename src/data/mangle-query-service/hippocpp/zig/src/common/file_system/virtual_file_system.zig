//! VirtualFileSystem
const std = @import("std");

pub const VirtualFileSystem = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) VirtualFileSystem {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *VirtualFileSystem) void {
        _ = self;
    }
};

test "VirtualFileSystem" {
    const allocator = std.testing.allocator;
    var instance = VirtualFileSystem.init(allocator);
    defer instance.deinit();
}

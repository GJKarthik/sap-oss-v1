//! LocalFileSystem
const std = @import("std");

pub const LocalFileSystem = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LocalFileSystem {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *LocalFileSystem) void {
        _ = self;
    }
};

test "LocalFileSystem" {
    const allocator = std.testing.allocator;
    var instance = LocalFileSystem.init(allocator);
    defer instance.deinit();
}

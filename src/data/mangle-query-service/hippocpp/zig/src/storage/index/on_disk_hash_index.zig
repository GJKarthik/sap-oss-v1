//! OnDiskHashIndex
const std = @import("std");

pub const OnDiskHashIndex = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) OnDiskHashIndex {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *OnDiskHashIndex) void {
        _ = self;
    }
};

test "OnDiskHashIndex" {
    const allocator = std.testing.allocator;
    var instance = OnDiskHashIndex.init(allocator);
    defer instance.deinit();
}

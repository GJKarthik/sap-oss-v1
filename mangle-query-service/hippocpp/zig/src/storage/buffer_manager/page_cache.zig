//! PageCache
const std = @import("std");

pub const PageCache = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) PageCache {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *PageCache) void {
        _ = self;
    }
};

test "PageCache" {
    const allocator = std.testing.allocator;
    var instance = PageCache.init(allocator);
    defer instance.deinit();
}

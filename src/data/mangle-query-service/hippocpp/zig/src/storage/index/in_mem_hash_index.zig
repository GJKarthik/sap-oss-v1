//! InMemHashIndex
const std = @import("std");

pub const InMemHashIndex = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) InMemHashIndex {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *InMemHashIndex) void {
        _ = self;
    }
};

test "InMemHashIndex" {
    const allocator = std.testing.allocator;
    var instance = InMemHashIndex.init(allocator);
    defer instance.deinit();
}

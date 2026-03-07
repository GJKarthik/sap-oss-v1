//! RadixSort
const std = @import("std");

pub const RadixSort = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) RadixSort {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *RadixSort) void {
        _ = self;
    }
};

test "RadixSort" {
    const allocator = std.testing.allocator;
    var instance = RadixSort.init(allocator);
    defer instance.deinit();
}

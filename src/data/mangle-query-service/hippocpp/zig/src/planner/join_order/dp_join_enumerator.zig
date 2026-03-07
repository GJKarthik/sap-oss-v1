//! DPJoinEnumerator
const std = @import("std");

pub const DPJoinEnumerator = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) DPJoinEnumerator {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *DPJoinEnumerator) void {
        _ = self;
    }
};

test "DPJoinEnumerator" {
    const allocator = std.testing.allocator;
    var instance = DPJoinEnumerator.init(allocator);
    defer instance.deinit();
}

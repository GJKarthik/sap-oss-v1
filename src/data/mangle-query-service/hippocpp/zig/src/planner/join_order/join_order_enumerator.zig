//! JoinOrderEnumerator
const std = @import("std");

pub const JoinOrderEnumerator = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) JoinOrderEnumerator {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *JoinOrderEnumerator) void {
        _ = self;
    }
};

test "JoinOrderEnumerator" {
    const allocator = std.testing.allocator;
    var instance = JoinOrderEnumerator.init(allocator);
    defer instance.deinit();
}

//! Intersect
const std = @import("std");

pub const Intersect = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Intersect {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Intersect) void {
        _ = self;
    }
};

test "Intersect" {
    const allocator = std.testing.allocator;
    var instance = Intersect.init(allocator);
    defer instance.deinit();
}

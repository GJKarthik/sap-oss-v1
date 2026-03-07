//! Interval
const std = @import("std");

pub const Interval = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Interval {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Interval) void {
        _ = self;
    }
};

test "Interval" {
    const allocator = std.testing.allocator;
    var instance = Interval.init(allocator);
    defer instance.deinit();
}

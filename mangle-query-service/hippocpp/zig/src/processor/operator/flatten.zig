//! Flatten
const std = @import("std");

pub const Flatten = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Flatten {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Flatten) void {
        _ = self;
    }
};

test "Flatten" {
    const allocator = std.testing.allocator;
    var instance = Flatten.init(allocator);
    defer instance.deinit();
}

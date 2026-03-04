//! Extend
const std = @import("std");

pub const Extend = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Extend {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Extend) void {
        _ = self;
    }
};

test "Extend" {
    const allocator = std.testing.allocator;
    var instance = Extend.init(allocator);
    defer instance.deinit();
}

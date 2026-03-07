//! Bitpacking
const std = @import("std");

pub const Bitpacking = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Bitpacking {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Bitpacking) void {
        _ = self;
    }
};

test "Bitpacking" {
    const allocator = std.testing.allocator;
    var instance = Bitpacking.init(allocator);
    defer instance.deinit();
}

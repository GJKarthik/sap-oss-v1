//! Accumulate
const std = @import("std");

pub const Accumulate = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Accumulate {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Accumulate) void {
        _ = self;
    }
};

test "Accumulate" {
    const allocator = std.testing.allocator;
    var instance = Accumulate.init(allocator);
    defer instance.deinit();
}

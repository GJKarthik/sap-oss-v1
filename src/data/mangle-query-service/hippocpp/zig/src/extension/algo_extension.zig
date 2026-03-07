//! AlgoExtension
const std = @import("std");

pub const AlgoExtension = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) AlgoExtension {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *AlgoExtension) void {
        _ = self;
    }
};

test "AlgoExtension" {
    const allocator = std.testing.allocator;
    var instance = AlgoExtension.init(allocator);
    defer instance.deinit();
}

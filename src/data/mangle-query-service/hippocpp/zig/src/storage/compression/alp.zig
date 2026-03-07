//! ALP
const std = @import("std");

pub const ALP = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ALP {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ALP) void {
        _ = self;
    }
};

test "ALP" {
    const allocator = std.testing.allocator;
    var instance = ALP.init(allocator);
    defer instance.deinit();
}

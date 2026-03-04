//! Skip
const std = @import("std");

pub const Skip = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Skip {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Skip) void {
        _ = self;
    }
};

test "Skip" {
    const allocator = std.testing.allocator;
    var instance = Skip.init(allocator);
    defer instance.deinit();
}

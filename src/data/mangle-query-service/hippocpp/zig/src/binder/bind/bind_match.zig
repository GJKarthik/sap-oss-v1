//! BindMatch
const std = @import("std");

pub const BindMatch = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BindMatch {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BindMatch) void {
        _ = self;
    }
};

test "BindMatch" {
    const allocator = std.testing.allocator;
    var instance = BindMatch.init(allocator);
    defer instance.deinit();
}

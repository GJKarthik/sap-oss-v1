//! BindWith
const std = @import("std");

pub const BindWith = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BindWith {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BindWith) void {
        _ = self;
    }
};

test "BindWith" {
    const allocator = std.testing.allocator;
    var instance = BindWith.init(allocator);
    defer instance.deinit();
}

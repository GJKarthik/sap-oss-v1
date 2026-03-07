//! BindRemove
const std = @import("std");

pub const BindRemove = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BindRemove {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BindRemove) void {
        _ = self;
    }
};

test "BindRemove" {
    const allocator = std.testing.allocator;
    var instance = BindRemove.init(allocator);
    defer instance.deinit();
}

//! BindMerge
const std = @import("std");

pub const BindMerge = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BindMerge {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BindMerge) void {
        _ = self;
    }
};

test "BindMerge" {
    const allocator = std.testing.allocator;
    var instance = BindMerge.init(allocator);
    defer instance.deinit();
}

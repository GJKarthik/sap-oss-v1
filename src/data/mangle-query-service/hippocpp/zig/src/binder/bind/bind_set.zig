//! BindSet
const std = @import("std");

pub const BindSet = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BindSet {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BindSet) void {
        _ = self;
    }
};

test "BindSet" {
    const allocator = std.testing.allocator;
    var instance = BindSet.init(allocator);
    defer instance.deinit();
}

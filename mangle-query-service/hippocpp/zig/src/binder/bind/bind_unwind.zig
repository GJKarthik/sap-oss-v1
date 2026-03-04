//! BindUnwind
const std = @import("std");

pub const BindUnwind = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BindUnwind {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BindUnwind) void {
        _ = self;
    }
};

test "BindUnwind" {
    const allocator = std.testing.allocator;
    var instance = BindUnwind.init(allocator);
    defer instance.deinit();
}

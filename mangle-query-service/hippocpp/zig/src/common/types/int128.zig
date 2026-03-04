//! Int128
const std = @import("std");

pub const Int128 = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Int128 {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *Int128) void {
        _ = self;
    }
};

test "Int128" {
    const allocator = std.testing.allocator;
    var instance = Int128.init(allocator);
    defer instance.deinit();
}

//! BindReturn
const std = @import("std");

pub const BindReturn = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BindReturn {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BindReturn) void {
        _ = self;
    }
};

test "BindReturn" {
    const allocator = std.testing.allocator;
    var instance = BindReturn.init(allocator);
    defer instance.deinit();
}

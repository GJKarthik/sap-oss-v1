//! BindCall
const std = @import("std");

pub const BindCall = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BindCall {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BindCall) void {
        _ = self;
    }
};

test "BindCall" {
    const allocator = std.testing.allocator;
    var instance = BindCall.init(allocator);
    defer instance.deinit();
}

//! ExpFunction
const std = @import("std");

pub const ExpFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ExpFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ExpFunction) void {
        _ = self;
    }
};

test "ExpFunction" {
    const allocator = std.testing.allocator;
    var instance = ExpFunction.init(allocator);
    defer instance.deinit();
}

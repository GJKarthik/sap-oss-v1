//! GreaterEqualsFunction
const std = @import("std");

pub const GreaterEqualsFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) GreaterEqualsFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *GreaterEqualsFunction) void {
        _ = self;
    }
};

test "GreaterEqualsFunction" {
    const allocator = std.testing.allocator;
    var instance = GreaterEqualsFunction.init(allocator);
    defer instance.deinit();
}

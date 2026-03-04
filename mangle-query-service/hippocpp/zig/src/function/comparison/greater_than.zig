//! GreaterThanFunction
const std = @import("std");

pub const GreaterThanFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) GreaterThanFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *GreaterThanFunction) void {
        _ = self;
    }
};

test "GreaterThanFunction" {
    const allocator = std.testing.allocator;
    var instance = GreaterThanFunction.init(allocator);
    defer instance.deinit();
}

//! IsNotNullFunction
const std = @import("std");

pub const IsNotNullFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) IsNotNullFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *IsNotNullFunction) void {
        _ = self;
    }
};

test "IsNotNullFunction" {
    const allocator = std.testing.allocator;
    var instance = IsNotNullFunction.init(allocator);
    defer instance.deinit();
}

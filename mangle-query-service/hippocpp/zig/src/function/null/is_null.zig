//! IsNullFunction
const std = @import("std");

pub const IsNullFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) IsNullFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *IsNullFunction) void {
        _ = self;
    }
};

test "IsNullFunction" {
    const allocator = std.testing.allocator;
    var instance = IsNullFunction.init(allocator);
    defer instance.deinit();
}

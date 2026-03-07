//! IfNullFunction
const std = @import("std");

pub const IfNullFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) IfNullFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *IfNullFunction) void {
        _ = self;
    }
};

test "IfNullFunction" {
    const allocator = std.testing.allocator;
    var instance = IfNullFunction.init(allocator);
    defer instance.deinit();
}

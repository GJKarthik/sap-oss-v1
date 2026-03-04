//! EqualsFunction
const std = @import("std");

pub const EqualsFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) EqualsFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *EqualsFunction) void {
        _ = self;
    }
};

test "EqualsFunction" {
    const allocator = std.testing.allocator;
    var instance = EqualsFunction.init(allocator);
    defer instance.deinit();
}

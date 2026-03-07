//! DivideFunction
const std = @import("std");

pub const DivideFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) DivideFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *DivideFunction) void {
        _ = self;
    }
};

test "DivideFunction" {
    const allocator = std.testing.allocator;
    var instance = DivideFunction.init(allocator);
    defer instance.deinit();
}

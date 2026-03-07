//! XorFunction
const std = @import("std");

pub const XorFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) XorFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *XorFunction) void {
        _ = self;
    }
};

test "XorFunction" {
    const allocator = std.testing.allocator;
    var instance = XorFunction.init(allocator);
    defer instance.deinit();
}

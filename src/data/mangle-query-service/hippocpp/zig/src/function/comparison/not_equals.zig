//! NotEqualsFunction
const std = @import("std");

pub const NotEqualsFunction = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) NotEqualsFunction {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *NotEqualsFunction) void {
        _ = self;
    }
};

test "NotEqualsFunction" {
    const allocator = std.testing.allocator;
    var instance = NotEqualsFunction.init(allocator);
    defer instance.deinit();
}

//! BoundFunctionExpression
const std = @import("std");

pub const BoundFunctionExpression = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BoundFunctionExpression {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BoundFunctionExpression) void {
        _ = self;
    }
};

test "BoundFunctionExpression" {
    const allocator = std.testing.allocator;
    var instance = BoundFunctionExpression.init(allocator);
    defer instance.deinit();
}

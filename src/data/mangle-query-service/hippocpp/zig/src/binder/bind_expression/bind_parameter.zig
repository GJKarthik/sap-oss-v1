//! BoundParameterExpression
const std = @import("std");

pub const BoundParameterExpression = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BoundParameterExpression {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BoundParameterExpression) void {
        _ = self;
    }
};

test "BoundParameterExpression" {
    const allocator = std.testing.allocator;
    var instance = BoundParameterExpression.init(allocator);
    defer instance.deinit();
}

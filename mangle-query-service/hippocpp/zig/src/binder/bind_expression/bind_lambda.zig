//! BoundLambdaExpression
const std = @import("std");

pub const BoundLambdaExpression = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BoundLambdaExpression {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BoundLambdaExpression) void {
        _ = self;
    }
};

test "BoundLambdaExpression" {
    const allocator = std.testing.allocator;
    var instance = BoundLambdaExpression.init(allocator);
    defer instance.deinit();
}

//! BoundLiteralExpression
const std = @import("std");

pub const BoundLiteralExpression = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BoundLiteralExpression {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BoundLiteralExpression) void {
        _ = self;
    }
};

test "BoundLiteralExpression" {
    const allocator = std.testing.allocator;
    var instance = BoundLiteralExpression.init(allocator);
    defer instance.deinit();
}

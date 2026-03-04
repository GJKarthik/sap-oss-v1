//! BoundPropertyExpression
const std = @import("std");

pub const BoundPropertyExpression = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BoundPropertyExpression {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BoundPropertyExpression) void {
        _ = self;
    }
};

test "BoundPropertyExpression" {
    const allocator = std.testing.allocator;
    var instance = BoundPropertyExpression.init(allocator);
    defer instance.deinit();
}

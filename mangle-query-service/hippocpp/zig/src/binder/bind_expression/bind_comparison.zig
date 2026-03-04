//! BoundComparisonExpression
const std = @import("std");

pub const BoundComparisonExpression = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BoundComparisonExpression {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BoundComparisonExpression) void {
        _ = self;
    }
};

test "BoundComparisonExpression" {
    const allocator = std.testing.allocator;
    var instance = BoundComparisonExpression.init(allocator);
    defer instance.deinit();
}

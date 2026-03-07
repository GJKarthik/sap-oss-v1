//! BoundVariableExpression
const std = @import("std");

pub const BoundVariableExpression = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BoundVariableExpression {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BoundVariableExpression) void {
        _ = self;
    }
};

test "BoundVariableExpression" {
    const allocator = std.testing.allocator;
    var instance = BoundVariableExpression.init(allocator);
    defer instance.deinit();
}

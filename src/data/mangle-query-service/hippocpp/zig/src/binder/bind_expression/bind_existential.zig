//! BoundExistentialExpression
const std = @import("std");

pub const BoundExistentialExpression = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BoundExistentialExpression {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BoundExistentialExpression) void {
        _ = self;
    }
};

test "BoundExistentialExpression" {
    const allocator = std.testing.allocator;
    var instance = BoundExistentialExpression.init(allocator);
    defer instance.deinit();
}

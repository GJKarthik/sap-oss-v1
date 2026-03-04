//! BoundSubqueryExpression
const std = @import("std");

pub const BoundSubqueryExpression = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BoundSubqueryExpression {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BoundSubqueryExpression) void {
        _ = self;
    }
};

test "BoundSubqueryExpression" {
    const allocator = std.testing.allocator;
    var instance = BoundSubqueryExpression.init(allocator);
    defer instance.deinit();
}

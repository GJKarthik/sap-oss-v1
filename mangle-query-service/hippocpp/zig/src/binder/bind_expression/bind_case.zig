//! BoundCaseExpression
const std = @import("std");

pub const BoundCaseExpression = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) BoundCaseExpression {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *BoundCaseExpression) void {
        _ = self;
    }
};

test "BoundCaseExpression" {
    const allocator = std.testing.allocator;
    var instance = BoundCaseExpression.init(allocator);
    defer instance.deinit();
}

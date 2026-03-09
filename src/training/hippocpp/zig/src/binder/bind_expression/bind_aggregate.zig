//! Bind Aggregate Expressions
const std = @import("std");

pub const BoundAggregateExpression = struct {
    function_name: []const u8,
    children: std.ArrayList(*anyopaque),
    distinct: bool = false,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8) BoundAggregateExpression {
        return .{
            .function_name = name,
            .children = .{},
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *BoundAggregateExpression) void {
        self.children.deinit(self.allocator);
    }
};

test "bound aggregate expression" {
    const allocator = std.testing.allocator;
    var expr = BoundAggregateExpression.init(allocator, "COUNT");
    defer expr.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("COUNT", expr.function_name);
}
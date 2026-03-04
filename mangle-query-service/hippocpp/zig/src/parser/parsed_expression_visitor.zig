//! ParsedExpressionVisitor
const std = @import("std");

pub const ParsedExpressionVisitor = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ParsedExpressionVisitor {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ParsedExpressionVisitor) void {
        _ = self;
    }
};

test "ParsedExpressionVisitor" {
    const allocator = std.testing.allocator;
    var instance = ParsedExpressionVisitor.init(allocator);
    defer instance.deinit();
}

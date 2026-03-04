//! TransactionStatement
const std = @import("std");

pub const TransactionStatement = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) TransactionStatement {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *TransactionStatement) void {
        _ = self;
    }
};

test "TransactionStatement" {
    const allocator = std.testing.allocator;
    var instance = TransactionStatement.init(allocator);
    defer instance.deinit();
}

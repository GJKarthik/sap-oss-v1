//! TransactionContext
const std = @import("std");

pub const TransactionContext = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) TransactionContext { return .{ .allocator = allocator }; }
    pub fn deinit(self: *TransactionContext) void { _ = self; }
};

test "TransactionContext" {
    const allocator = std.testing.allocator;
    var instance = TransactionContext.init(allocator);
    defer instance.deinit();
}

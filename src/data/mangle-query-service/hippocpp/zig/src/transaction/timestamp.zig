//! TransactionTimestamp
const std = @import("std");

pub const TransactionTimestamp = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) TransactionTimestamp { return .{ .allocator = allocator }; }
    pub fn deinit(self: *TransactionTimestamp) void { _ = self; }
};

test "TransactionTimestamp" {
    const allocator = std.testing.allocator;
    var instance = TransactionTimestamp.init(allocator);
    defer instance.deinit();
}

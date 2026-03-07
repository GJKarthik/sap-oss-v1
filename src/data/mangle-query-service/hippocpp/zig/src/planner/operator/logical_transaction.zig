//! LogicalTransaction
const std = @import("std");

pub const LogicalTransaction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalTransaction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalTransaction) void { _ = self; }
};

test "LogicalTransaction" {
    const allocator = std.testing.allocator;
    var instance = LogicalTransaction.init(allocator);
    defer instance.deinit();
}

//! ActiveTransactions
const std = @import("std");

pub const ActiveTransactions = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ActiveTransactions { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ActiveTransactions) void { _ = self; }
};

test "ActiveTransactions" {
    const allocator = std.testing.allocator;
    var instance = ActiveTransactions.init(allocator);
    defer instance.deinit();
}

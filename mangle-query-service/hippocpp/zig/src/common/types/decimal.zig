//! Decimal
const std = @import("std");

pub const Decimal = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Decimal { return .{ .allocator = allocator }; }
    pub fn deinit(self: *Decimal) void { _ = self; }
};

test "Decimal" {
    const allocator = std.testing.allocator;
    var instance = Decimal.init(allocator);
    defer instance.deinit();
}

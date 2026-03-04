//! BoundRegularQuery
const std = @import("std");

pub const BoundRegularQuery = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BoundRegularQuery { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BoundRegularQuery) void { _ = self; }
};

test "BoundRegularQuery" {
    const allocator = std.testing.allocator;
    var instance = BoundRegularQuery.init(allocator);
    defer instance.deinit();
}

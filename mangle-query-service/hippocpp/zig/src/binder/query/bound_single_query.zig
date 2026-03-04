//! BoundSingleQuery
const std = @import("std");

pub const BoundSingleQuery = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BoundSingleQuery { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BoundSingleQuery) void { _ = self; }
};

test "BoundSingleQuery" {
    const allocator = std.testing.allocator;
    var instance = BoundSingleQuery.init(allocator);
    defer instance.deinit();
}

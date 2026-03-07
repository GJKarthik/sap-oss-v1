//! SingleQuery
const std = @import("std");

pub const SingleQuery = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) SingleQuery { return .{ .allocator = allocator }; }
    pub fn deinit(self: *SingleQuery) void { _ = self; }
};

test "SingleQuery" {
    const allocator = std.testing.allocator;
    var instance = SingleQuery.init(allocator);
    defer instance.deinit();
}

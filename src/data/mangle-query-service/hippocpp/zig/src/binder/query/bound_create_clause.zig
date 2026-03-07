//! BoundCreateClause
const std = @import("std");

pub const BoundCreateClause = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BoundCreateClause { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BoundCreateClause) void { _ = self; }
};

test "BoundCreateClause" {
    const allocator = std.testing.allocator;
    var instance = BoundCreateClause.init(allocator);
    defer instance.deinit();
}

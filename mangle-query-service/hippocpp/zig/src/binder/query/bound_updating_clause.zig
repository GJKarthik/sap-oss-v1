//! BoundUpdatingClause
const std = @import("std");

pub const BoundUpdatingClause = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BoundUpdatingClause { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BoundUpdatingClause) void { _ = self; }
};

test "BoundUpdatingClause" {
    const allocator = std.testing.allocator;
    var instance = BoundUpdatingClause.init(allocator);
    defer instance.deinit();
}

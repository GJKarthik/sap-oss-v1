//! BoundDeleteClause
const std = @import("std");

pub const BoundDeleteClause = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BoundDeleteClause { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BoundDeleteClause) void { _ = self; }
};

test "BoundDeleteClause" {
    const allocator = std.testing.allocator;
    var instance = BoundDeleteClause.init(allocator);
    defer instance.deinit();
}

//! BoundSetClause
const std = @import("std");

pub const BoundSetClause = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BoundSetClause { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BoundSetClause) void { _ = self; }
};

test "BoundSetClause" {
    const allocator = std.testing.allocator;
    var instance = BoundSetClause.init(allocator);
    defer instance.deinit();
}

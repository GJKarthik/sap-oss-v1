//! BoundReadingClause
const std = @import("std");

pub const BoundReadingClause = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BoundReadingClause { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BoundReadingClause) void { _ = self; }
};

test "BoundReadingClause" {
    const allocator = std.testing.allocator;
    var instance = BoundReadingClause.init(allocator);
    defer instance.deinit();
}

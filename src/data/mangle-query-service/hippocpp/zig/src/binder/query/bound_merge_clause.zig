//! BoundMergeClause
const std = @import("std");

pub const BoundMergeClause = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BoundMergeClause { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BoundMergeClause) void { _ = self; }
};

test "BoundMergeClause" {
    const allocator = std.testing.allocator;
    var instance = BoundMergeClause.init(allocator);
    defer instance.deinit();
}

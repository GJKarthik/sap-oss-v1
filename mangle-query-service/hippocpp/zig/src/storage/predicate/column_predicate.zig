//! ColumnPredicate
const std = @import("std");

pub const ColumnPredicate = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ColumnPredicate { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ColumnPredicate) void { _ = self; }
};

test "ColumnPredicate" {
    const allocator = std.testing.allocator;
    var instance = ColumnPredicate.init(allocator);
    defer instance.deinit();
}

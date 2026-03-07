//! UnionColumn
const std = @import("std");

pub const UnionColumn = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) UnionColumn { return .{ .allocator = allocator }; }
    pub fn deinit(self: *UnionColumn) void { _ = self; }
};

test "UnionColumn" {
    const allocator = std.testing.allocator;
    var instance = UnionColumn.init(allocator);
    defer instance.deinit();
}

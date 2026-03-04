//! DoubleColumn
const std = @import("std");

pub const DoubleColumn = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) DoubleColumn { return .{ .allocator = allocator }; }
    pub fn deinit(self: *DoubleColumn) void { _ = self; }
};

test "DoubleColumn" {
    const allocator = std.testing.allocator;
    var instance = DoubleColumn.init(allocator);
    defer instance.deinit();
}

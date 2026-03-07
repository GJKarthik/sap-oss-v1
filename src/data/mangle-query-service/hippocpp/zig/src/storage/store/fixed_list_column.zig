//! FixedListColumn
const std = @import("std");

pub const FixedListColumn = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) FixedListColumn { return .{ .allocator = allocator }; }
    pub fn deinit(self: *FixedListColumn) void { _ = self; }
};

test "FixedListColumn" {
    const allocator = std.testing.allocator;
    var instance = FixedListColumn.init(allocator);
    defer instance.deinit();
}

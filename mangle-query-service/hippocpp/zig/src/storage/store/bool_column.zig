//! BoolColumn
const std = @import("std");

pub const BoolColumn = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BoolColumn { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BoolColumn) void { _ = self; }
};

test "BoolColumn" {
    const allocator = std.testing.allocator;
    var instance = BoolColumn.init(allocator);
    defer instance.deinit();
}

//! FloatColumn
const std = @import("std");

pub const FloatColumn = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) FloatColumn { return .{ .allocator = allocator }; }
    pub fn deinit(self: *FloatColumn) void { _ = self; }
};

test "FloatColumn" {
    const allocator = std.testing.allocator;
    var instance = FloatColumn.init(allocator);
    defer instance.deinit();
}

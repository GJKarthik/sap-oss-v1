//! DateColumn
const std = @import("std");

pub const DateColumn = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) DateColumn { return .{ .allocator = allocator }; }
    pub fn deinit(self: *DateColumn) void { _ = self; }
};

test "DateColumn" {
    const allocator = std.testing.allocator;
    var instance = DateColumn.init(allocator);
    defer instance.deinit();
}

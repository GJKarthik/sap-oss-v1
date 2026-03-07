//! ArrayColumn
const std = @import("std");

pub const ArrayColumn = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ArrayColumn { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ArrayColumn) void { _ = self; }
};

test "ArrayColumn" {
    const allocator = std.testing.allocator;
    var instance = ArrayColumn.init(allocator);
    defer instance.deinit();
}

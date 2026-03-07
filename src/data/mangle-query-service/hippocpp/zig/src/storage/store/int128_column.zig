//! Int128Column
const std = @import("std");

pub const Int128Column = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Int128Column { return .{ .allocator = allocator }; }
    pub fn deinit(self: *Int128Column) void { _ = self; }
};

test "Int128Column" {
    const allocator = std.testing.allocator;
    var instance = Int128Column.init(allocator);
    defer instance.deinit();
}

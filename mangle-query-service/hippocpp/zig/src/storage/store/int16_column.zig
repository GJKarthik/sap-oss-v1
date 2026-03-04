//! Int16Column
const std = @import("std");

pub const Int16Column = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Int16Column { return .{ .allocator = allocator }; }
    pub fn deinit(self: *Int16Column) void { _ = self; }
};

test "Int16Column" {
    const allocator = std.testing.allocator;
    var instance = Int16Column.init(allocator);
    defer instance.deinit();
}

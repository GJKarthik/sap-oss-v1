//! Int32Column
const std = @import("std");

pub const Int32Column = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Int32Column { return .{ .allocator = allocator }; }
    pub fn deinit(self: *Int32Column) void { _ = self; }
};

test "Int32Column" {
    const allocator = std.testing.allocator;
    var instance = Int32Column.init(allocator);
    defer instance.deinit();
}

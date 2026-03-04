//! Int8Column
const std = @import("std");

pub const Int8Column = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Int8Column { return .{ .allocator = allocator }; }
    pub fn deinit(self: *Int8Column) void { _ = self; }
};

test "Int8Column" {
    const allocator = std.testing.allocator;
    var instance = Int8Column.init(allocator);
    defer instance.deinit();
}

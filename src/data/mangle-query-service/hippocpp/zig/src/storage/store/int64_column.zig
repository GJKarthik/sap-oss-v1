//! Int64Column
const std = @import("std");

pub const Int64Column = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Int64Column { return .{ .allocator = allocator }; }
    pub fn deinit(self: *Int64Column) void { _ = self; }
};

test "Int64Column" {
    const allocator = std.testing.allocator;
    var instance = Int64Column.init(allocator);
    defer instance.deinit();
}

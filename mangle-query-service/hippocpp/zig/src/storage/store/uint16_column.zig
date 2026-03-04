//! UInt16Column
const std = @import("std");

pub const UInt16Column = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) UInt16Column { return .{ .allocator = allocator }; }
    pub fn deinit(self: *UInt16Column) void { _ = self; }
};

test "UInt16Column" {
    const allocator = std.testing.allocator;
    var instance = UInt16Column.init(allocator);
    defer instance.deinit();
}

//! UInt64Column
const std = @import("std");

pub const UInt64Column = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) UInt64Column { return .{ .allocator = allocator }; }
    pub fn deinit(self: *UInt64Column) void { _ = self; }
};

test "UInt64Column" {
    const allocator = std.testing.allocator;
    var instance = UInt64Column.init(allocator);
    defer instance.deinit();
}

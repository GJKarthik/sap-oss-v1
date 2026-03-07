//! UInt32Column
const std = @import("std");

pub const UInt32Column = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) UInt32Column { return .{ .allocator = allocator }; }
    pub fn deinit(self: *UInt32Column) void { _ = self; }
};

test "UInt32Column" {
    const allocator = std.testing.allocator;
    var instance = UInt32Column.init(allocator);
    defer instance.deinit();
}

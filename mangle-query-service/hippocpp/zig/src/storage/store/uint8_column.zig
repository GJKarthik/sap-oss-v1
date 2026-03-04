//! UInt8Column
const std = @import("std");

pub const UInt8Column = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) UInt8Column { return .{ .allocator = allocator }; }
    pub fn deinit(self: *UInt8Column) void { _ = self; }
};

test "UInt8Column" {
    const allocator = std.testing.allocator;
    var instance = UInt8Column.init(allocator);
    defer instance.deinit();
}

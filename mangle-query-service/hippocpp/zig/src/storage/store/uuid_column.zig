//! UUIDColumn
const std = @import("std");

pub const UUIDColumn = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) UUIDColumn { return .{ .allocator = allocator }; }
    pub fn deinit(self: *UUIDColumn) void { _ = self; }
};

test "UUIDColumn" {
    const allocator = std.testing.allocator;
    var instance = UUIDColumn.init(allocator);
    defer instance.deinit();
}

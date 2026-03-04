//! TimestampColumn
const std = @import("std");

pub const TimestampColumn = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) TimestampColumn { return .{ .allocator = allocator }; }
    pub fn deinit(self: *TimestampColumn) void { _ = self; }
};

test "TimestampColumn" {
    const allocator = std.testing.allocator;
    var instance = TimestampColumn.init(allocator);
    defer instance.deinit();
}

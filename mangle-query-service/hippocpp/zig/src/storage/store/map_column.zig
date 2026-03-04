//! MapColumn
const std = @import("std");

pub const MapColumn = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) MapColumn { return .{ .allocator = allocator }; }
    pub fn deinit(self: *MapColumn) void { _ = self; }
};

test "MapColumn" {
    const allocator = std.testing.allocator;
    var instance = MapColumn.init(allocator);
    defer instance.deinit();
}

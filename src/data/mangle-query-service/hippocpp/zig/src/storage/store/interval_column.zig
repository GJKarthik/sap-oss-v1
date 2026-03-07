//! IntervalColumn
const std = @import("std");

pub const IntervalColumn = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) IntervalColumn { return .{ .allocator = allocator }; }
    pub fn deinit(self: *IntervalColumn) void { _ = self; }
};

test "IntervalColumn" {
    const allocator = std.testing.allocator;
    var instance = IntervalColumn.init(allocator);
    defer instance.deinit();
}

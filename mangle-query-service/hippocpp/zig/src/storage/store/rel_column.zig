//! RelColumn
const std = @import("std");

pub const RelColumn = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) RelColumn { return .{ .allocator = allocator }; }
    pub fn deinit(self: *RelColumn) void { _ = self; }
};

test "RelColumn" {
    const allocator = std.testing.allocator;
    var instance = RelColumn.init(allocator);
    defer instance.deinit();
}

//! RowLayout
const std = @import("std");

pub const RowLayout = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) RowLayout { return .{ .allocator = allocator }; }
    pub fn deinit(self: *RowLayout) void { _ = self; }
};

test "RowLayout" {
    const allocator = std.testing.allocator;
    var instance = RowLayout.init(allocator);
    defer instance.deinit();
}

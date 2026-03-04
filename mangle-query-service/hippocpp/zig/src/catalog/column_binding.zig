//! ColumnBinding
const std = @import("std");

pub const ColumnBinding = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ColumnBinding { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ColumnBinding) void { _ = self; }
};

test "ColumnBinding" {
    const allocator = std.testing.allocator;
    var instance = ColumnBinding.init(allocator);
    defer instance.deinit();
}

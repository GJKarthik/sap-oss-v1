//! LogicalDrop
const std = @import("std");

pub const LogicalDrop = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalDrop { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalDrop) void { _ = self; }
};

test "LogicalDrop" {
    const allocator = std.testing.allocator;
    var instance = LogicalDrop.init(allocator);
    defer instance.deinit();
}

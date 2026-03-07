//! LogicalAlter
const std = @import("std");

pub const LogicalAlter = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalAlter { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalAlter) void { _ = self; }
};

test "LogicalAlter" {
    const allocator = std.testing.allocator;
    var instance = LogicalAlter.init(allocator);
    defer instance.deinit();
}

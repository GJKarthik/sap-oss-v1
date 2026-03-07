//! LogicalPartition
const std = @import("std");

pub const LogicalPartition = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalPartition { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalPartition) void { _ = self; }
};

test "LogicalPartition" {
    const allocator = std.testing.allocator;
    var instance = LogicalPartition.init(allocator);
    defer instance.deinit();
}

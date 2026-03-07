//! LogicalCopyFrom
const std = @import("std");

pub const LogicalCopyFrom = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalCopyFrom { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalCopyFrom) void { _ = self; }
};

test "LogicalCopyFrom" {
    const allocator = std.testing.allocator;
    var instance = LogicalCopyFrom.init(allocator);
    defer instance.deinit();
}

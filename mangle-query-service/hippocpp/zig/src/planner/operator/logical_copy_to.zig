//! LogicalCopyTo
const std = @import("std");

pub const LogicalCopyTo = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalCopyTo { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalCopyTo) void { _ = self; }
};

test "LogicalCopyTo" {
    const allocator = std.testing.allocator;
    var instance = LogicalCopyTo.init(allocator);
    defer instance.deinit();
}

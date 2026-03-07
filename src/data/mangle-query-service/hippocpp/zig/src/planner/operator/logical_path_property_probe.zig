//! LogicalPathPropertyProbe
const std = @import("std");

pub const LogicalPathPropertyProbe = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalPathPropertyProbe { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalPathPropertyProbe) void { _ = self; }
};

test "LogicalPathPropertyProbe" {
    const allocator = std.testing.allocator;
    var instance = LogicalPathPropertyProbe.init(allocator);
    defer instance.deinit();
}

//! LogicalAttach
const std = @import("std");

pub const LogicalAttach = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalAttach { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalAttach) void { _ = self; }
};

test "LogicalAttach" {
    const allocator = std.testing.allocator;
    var instance = LogicalAttach.init(allocator);
    defer instance.deinit();
}

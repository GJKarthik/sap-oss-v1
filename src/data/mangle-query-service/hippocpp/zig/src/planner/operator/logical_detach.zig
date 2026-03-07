//! LogicalDetach
const std = @import("std");

pub const LogicalDetach = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalDetach { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalDetach) void { _ = self; }
};

test "LogicalDetach" {
    const allocator = std.testing.allocator;
    var instance = LogicalDetach.init(allocator);
    defer instance.deinit();
}

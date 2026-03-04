//! LogicalCreateType
const std = @import("std");

pub const LogicalCreateType = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalCreateType { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalCreateType) void { _ = self; }
};

test "LogicalCreateType" {
    const allocator = std.testing.allocator;
    var instance = LogicalCreateType.init(allocator);
    defer instance.deinit();
}

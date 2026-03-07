//! LogicalType
const std = @import("std");

pub const LogicalType = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalType { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalType) void { _ = self; }
};

test "LogicalType" {
    const allocator = std.testing.allocator;
    var instance = LogicalType.init(allocator);
    defer instance.deinit();
}

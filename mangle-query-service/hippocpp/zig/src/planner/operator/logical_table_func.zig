//! LogicalTableFunc
const std = @import("std");

pub const LogicalTableFunc = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalTableFunc { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalTableFunc) void { _ = self; }
};

test "LogicalTableFunc" {
    const allocator = std.testing.allocator;
    var instance = LogicalTableFunc.init(allocator);
    defer instance.deinit();
}

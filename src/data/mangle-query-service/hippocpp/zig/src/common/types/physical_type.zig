//! PhysicalType
const std = @import("std");

pub const PhysicalType = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) PhysicalType { return .{ .allocator = allocator }; }
    pub fn deinit(self: *PhysicalType) void { _ = self; }
};

test "PhysicalType" {
    const allocator = std.testing.allocator;
    var instance = PhysicalType.init(allocator);
    defer instance.deinit();
}

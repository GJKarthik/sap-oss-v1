//! NestedType
const std = @import("std");

pub const NestedType = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) NestedType { return .{ .allocator = allocator }; }
    pub fn deinit(self: *NestedType) void { _ = self; }
};

test "NestedType" {
    const allocator = std.testing.allocator;
    var instance = NestedType.init(allocator);
    defer instance.deinit();
}

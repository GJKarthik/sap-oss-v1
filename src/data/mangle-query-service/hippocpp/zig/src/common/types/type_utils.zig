//! TypeUtils
const std = @import("std");

pub const TypeUtils = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) TypeUtils { return .{ .allocator = allocator }; }
    pub fn deinit(self: *TypeUtils) void { _ = self; }
};

test "TypeUtils" {
    const allocator = std.testing.allocator;
    var instance = TypeUtils.init(allocator);
    defer instance.deinit();
}

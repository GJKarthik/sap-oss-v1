//! BindAddProperty
const std = @import("std");

pub const BindAddProperty = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BindAddProperty { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BindAddProperty) void { _ = self; }
};

test "BindAddProperty" {
    const allocator = std.testing.allocator;
    var instance = BindAddProperty.init(allocator);
    defer instance.deinit();
}

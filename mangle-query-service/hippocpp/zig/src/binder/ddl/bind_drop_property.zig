//! BindDropProperty
const std = @import("std");

pub const BindDropProperty = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BindDropProperty { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BindDropProperty) void { _ = self; }
};

test "BindDropProperty" {
    const allocator = std.testing.allocator;
    var instance = BindDropProperty.init(allocator);
    defer instance.deinit();
}

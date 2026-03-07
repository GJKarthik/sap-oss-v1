//! BindRenameProperty
const std = @import("std");

pub const BindRenameProperty = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BindRenameProperty { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BindRenameProperty) void { _ = self; }
};

test "BindRenameProperty" {
    const allocator = std.testing.allocator;
    var instance = BindRenameProperty.init(allocator);
    defer instance.deinit();
}

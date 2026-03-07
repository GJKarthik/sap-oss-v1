//! PropertyDefinition
const std = @import("std");

pub const PropertyDefinition = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) PropertyDefinition { return .{ .allocator = allocator }; }
    pub fn deinit(self: *PropertyDefinition) void { _ = self; }
};

test "PropertyDefinition" {
    const allocator = std.testing.allocator;
    var instance = PropertyDefinition.init(allocator);
    defer instance.deinit();
}

//! PropertyCollectorVisitor
const std = @import("std");

pub const PropertyCollectorVisitor = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) PropertyCollectorVisitor { return .{ .allocator = allocator }; }
    pub fn deinit(self: *PropertyCollectorVisitor) void { _ = self; }
};

test "PropertyCollectorVisitor" {
    const allocator = std.testing.allocator;
    var instance = PropertyCollectorVisitor.init(allocator);
    defer instance.deinit();
}

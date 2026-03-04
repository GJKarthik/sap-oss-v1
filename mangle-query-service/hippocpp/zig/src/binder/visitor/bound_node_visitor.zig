//! BoundNodeVisitor
const std = @import("std");

pub const BoundNodeVisitor = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BoundNodeVisitor { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BoundNodeVisitor) void { _ = self; }
};

test "BoundNodeVisitor" {
    const allocator = std.testing.allocator;
    var instance = BoundNodeVisitor.init(allocator);
    defer instance.deinit();
}

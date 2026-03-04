//! NodeVector
const std = @import("std");

pub const NodeVector = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) NodeVector { return .{ .allocator = allocator }; }
    pub fn deinit(self: *NodeVector) void { _ = self; }
};

test "NodeVector" {
    const allocator = std.testing.allocator;
    var instance = NodeVector.init(allocator);
    defer instance.deinit();
}

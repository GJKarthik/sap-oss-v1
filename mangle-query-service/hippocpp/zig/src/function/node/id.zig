//! NodeIDFunction
const std = @import("std");

pub const NodeIDFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) NodeIDFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *NodeIDFunction) void { _ = self; }
};

test "NodeIDFunction" {
    const allocator = std.testing.allocator;
    var instance = NodeIDFunction.init(allocator);
    defer instance.deinit();
}

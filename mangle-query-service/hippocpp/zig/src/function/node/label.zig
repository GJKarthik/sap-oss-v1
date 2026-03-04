//! NodeLabelFunction
const std = @import("std");

pub const NodeLabelFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) NodeLabelFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *NodeLabelFunction) void { _ = self; }
};

test "NodeLabelFunction" {
    const allocator = std.testing.allocator;
    var instance = NodeLabelFunction.init(allocator);
    defer instance.deinit();
}

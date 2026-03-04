//! NodeOffsetFunction
const std = @import("std");

pub const NodeOffsetFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) NodeOffsetFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *NodeOffsetFunction) void { _ = self; }
};

test "NodeOffsetFunction" {
    const allocator = std.testing.allocator;
    var instance = NodeOffsetFunction.init(allocator);
    defer instance.deinit();
}

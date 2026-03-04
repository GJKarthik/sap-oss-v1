//! NodeBatchInsert
const std = @import("std");

pub const NodeBatchInsert = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) NodeBatchInsert { return .{ .allocator = allocator }; }
    pub fn deinit(self: *NodeBatchInsert) void { _ = self; }
};

test "NodeBatchInsert" {
    const allocator = std.testing.allocator;
    var instance = NodeBatchInsert.init(allocator);
    defer instance.deinit();
}

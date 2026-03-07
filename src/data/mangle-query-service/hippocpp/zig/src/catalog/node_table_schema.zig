//! NodeTableSchema
const std = @import("std");

pub const NodeTableSchema = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) NodeTableSchema { return .{ .allocator = allocator }; }
    pub fn deinit(self: *NodeTableSchema) void { _ = self; }
};

test "NodeTableSchema" {
    const allocator = std.testing.allocator;
    var instance = NodeTableSchema.init(allocator);
    defer instance.deinit();
}

//! CopyNode
const std = @import("std");

pub const CopyNode = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) CopyNode { return .{ .allocator = allocator }; }
    pub fn deinit(self: *CopyNode) void { _ = self; }
};

test "CopyNode" {
    const allocator = std.testing.allocator;
    var instance = CopyNode.init(allocator);
    defer instance.deinit();
}

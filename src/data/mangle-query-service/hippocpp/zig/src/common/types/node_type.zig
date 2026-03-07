//! NodeType
const std = @import("std");

pub const NodeType = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) NodeType {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *NodeType) void {
        _ = self;
    }
};

test "NodeType" {
    const allocator = std.testing.allocator;
    var instance = NodeType.init(allocator);
    defer instance.deinit();
}

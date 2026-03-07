//! NodeGroupCollection
const std = @import("std");

pub const NodeGroupCollection = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) NodeGroupCollection {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *NodeGroupCollection) void {
        _ = self;
    }
};

test "NodeGroupCollection" {
    const allocator = std.testing.allocator;
    var instance = NodeGroupCollection.init(allocator);
    defer instance.deinit();
}

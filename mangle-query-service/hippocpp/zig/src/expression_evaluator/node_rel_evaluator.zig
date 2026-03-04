//! NodeRelEvaluator
const std = @import("std");

pub const NodeRelEvaluator = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) NodeRelEvaluator {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *NodeRelEvaluator) void {
        _ = self;
    }
};

test "NodeRelEvaluator" {
    const allocator = std.testing.allocator;
    var instance = NodeRelEvaluator.init(allocator);
    defer instance.deinit();
}

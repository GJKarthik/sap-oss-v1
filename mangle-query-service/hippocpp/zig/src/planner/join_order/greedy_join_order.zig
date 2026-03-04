//! GreedyJoinOrder
const std = @import("std");

pub const GreedyJoinOrder = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) GreedyJoinOrder {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *GreedyJoinOrder) void {
        _ = self;
    }
};

test "GreedyJoinOrder" {
    const allocator = std.testing.allocator;
    var instance = GreedyJoinOrder.init(allocator);
    defer instance.deinit();
}

//! AggregateState
const std = @import("std");

pub const AggregateState = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) AggregateState {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *AggregateState) void {
        _ = self;
    }
};

test "AggregateState" {
    const allocator = std.testing.allocator;
    var instance = AggregateState.init(allocator);
    defer instance.deinit();
}

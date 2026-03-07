//! CardinalityEstimator
const std = @import("std");

pub const CardinalityEstimator = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) CardinalityEstimator {
        return .{ .allocator = allocator };
    }
    
    pub fn deinit(self: *CardinalityEstimator) void {
        _ = self;
    }
};

test "CardinalityEstimator" {
    const allocator = std.testing.allocator;
    var instance = CardinalityEstimator.init(allocator);
    defer instance.deinit();
}

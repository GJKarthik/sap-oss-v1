//! TopKOptimizer
const std = @import("std");

pub const TopKOptimizer = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) TopKOptimizer { return .{ .allocator = allocator }; }
    pub fn deinit(self: *TopKOptimizer) void { _ = self; }
};

test "TopKOptimizer" {
    const allocator = std.testing.allocator;
    var instance = TopKOptimizer.init(allocator);
    defer instance.deinit();
}

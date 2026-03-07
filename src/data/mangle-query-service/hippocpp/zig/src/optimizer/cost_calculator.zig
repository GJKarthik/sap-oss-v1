//! CostCalculator
const std = @import("std");

pub const CostCalculator = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) CostCalculator { return .{ .allocator = allocator }; }
    pub fn deinit(self: *CostCalculator) void { _ = self; }
};

test "CostCalculator" {
    const allocator = std.testing.allocator;
    var instance = CostCalculator.init(allocator);
    defer instance.deinit();
}

//! PlanCostEstimation
const std = @import("std");

pub const PlanCostEstimation = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) PlanCostEstimation { return .{ .allocator = allocator }; }
    pub fn deinit(self: *PlanCostEstimation) void { _ = self; }
};

test "PlanCostEstimation" {
    const allocator = std.testing.allocator;
    var instance = PlanCostEstimation.init(allocator);
    defer instance.deinit();
}

//! LogicalPlanUtil
const std = @import("std");

pub const LogicalPlanUtil = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LogicalPlanUtil { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LogicalPlanUtil) void { _ = self; }
};

test "LogicalPlanUtil" {
    const allocator = std.testing.allocator;
    var instance = LogicalPlanUtil.init(allocator);
    defer instance.deinit();
}

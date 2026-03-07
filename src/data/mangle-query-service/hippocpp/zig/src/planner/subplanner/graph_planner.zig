//! GraphPlanner
const std = @import("std");

pub const GraphPlanner = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) GraphPlanner { return .{ .allocator = allocator }; }
    pub fn deinit(self: *GraphPlanner) void { _ = self; }
};

test "GraphPlanner" {
    const allocator = std.testing.allocator;
    var instance = GraphPlanner.init(allocator);
    defer instance.deinit();
}

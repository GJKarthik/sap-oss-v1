//! ProjectionPlanner
const std = @import("std");

pub const ProjectionPlanner = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ProjectionPlanner { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ProjectionPlanner) void { _ = self; }
};

test "ProjectionPlanner" {
    const allocator = std.testing.allocator;
    var instance = ProjectionPlanner.init(allocator);
    defer instance.deinit();
}

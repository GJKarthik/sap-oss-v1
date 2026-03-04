//! PathPlanner
const std = @import("std");

pub const PathPlanner = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) PathPlanner { return .{ .allocator = allocator }; }
    pub fn deinit(self: *PathPlanner) void { _ = self; }
};

test "PathPlanner" {
    const allocator = std.testing.allocator;
    var instance = PathPlanner.init(allocator);
    defer instance.deinit();
}

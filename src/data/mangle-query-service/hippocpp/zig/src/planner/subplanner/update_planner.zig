//! UpdatePlanner
const std = @import("std");

pub const UpdatePlanner = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) UpdatePlanner { return .{ .allocator = allocator }; }
    pub fn deinit(self: *UpdatePlanner) void { _ = self; }
};

test "UpdatePlanner" {
    const allocator = std.testing.allocator;
    var instance = UpdatePlanner.init(allocator);
    defer instance.deinit();
}

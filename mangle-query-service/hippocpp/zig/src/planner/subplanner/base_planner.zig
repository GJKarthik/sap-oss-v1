//! BasePlanner
const std = @import("std");

pub const BasePlanner = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BasePlanner { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BasePlanner) void { _ = self; }
};

test "BasePlanner" {
    const allocator = std.testing.allocator;
    var instance = BasePlanner.init(allocator);
    defer instance.deinit();
}

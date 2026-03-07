//! LoadFrom
const std = @import("std");

pub const LoadFrom = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LoadFrom { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LoadFrom) void { _ = self; }
};

test "LoadFrom" {
    const allocator = std.testing.allocator;
    var instance = LoadFrom.init(allocator);
    defer instance.deinit();
}

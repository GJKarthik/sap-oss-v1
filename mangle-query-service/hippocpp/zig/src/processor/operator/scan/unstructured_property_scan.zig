//! UnstructuredPropertyScan
const std = @import("std");

pub const UnstructuredPropertyScan = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) UnstructuredPropertyScan { return .{ .allocator = allocator }; }
    pub fn deinit(self: *UnstructuredPropertyScan) void { _ = self; }
};

test "UnstructuredPropertyScan" {
    const allocator = std.testing.allocator;
    var instance = UnstructuredPropertyScan.init(allocator);
    defer instance.deinit();
}

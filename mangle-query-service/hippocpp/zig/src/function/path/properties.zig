//! PathPropertiesFunction
const std = @import("std");

pub const PathPropertiesFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) PathPropertiesFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *PathPropertiesFunction) void { _ = self; }
};

test "PathPropertiesFunction" {
    const allocator = std.testing.allocator;
    var instance = PathPropertiesFunction.init(allocator);
    defer instance.deinit();
}

//! NodesFunction
const std = @import("std");

pub const NodesFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) NodesFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *NodesFunction) void { _ = self; }
};

test "NodesFunction" {
    const allocator = std.testing.allocator;
    var instance = NodesFunction.init(allocator);
    defer instance.deinit();
}

//! WeaklyConnectedFunction
const std = @import("std");

pub const WeaklyConnectedFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) WeaklyConnectedFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *WeaklyConnectedFunction) void { _ = self; }
};

test "WeaklyConnectedFunction" {
    const allocator = std.testing.allocator;
    var instance = WeaklyConnectedFunction.init(allocator);
    defer instance.deinit();
}

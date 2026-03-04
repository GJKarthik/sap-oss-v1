//! StronglyConnectedFunction
const std = @import("std");

pub const StronglyConnectedFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) StronglyConnectedFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *StronglyConnectedFunction) void { _ = self; }
};

test "StronglyConnectedFunction" {
    const allocator = std.testing.allocator;
    var instance = StronglyConnectedFunction.init(allocator);
    defer instance.deinit();
}

//! BetweennessFunction
const std = @import("std");

pub const BetweennessFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) BetweennessFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *BetweennessFunction) void { _ = self; }
};

test "BetweennessFunction" {
    const allocator = std.testing.allocator;
    var instance = BetweennessFunction.init(allocator);
    defer instance.deinit();
}

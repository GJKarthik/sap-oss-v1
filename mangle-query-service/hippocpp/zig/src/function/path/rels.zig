//! RelsFunction
const std = @import("std");

pub const RelsFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) RelsFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *RelsFunction) void { _ = self; }
};

test "RelsFunction" {
    const allocator = std.testing.allocator;
    var instance = RelsFunction.init(allocator);
    defer instance.deinit();
}

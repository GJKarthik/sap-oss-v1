//! RelTypeFunction
const std = @import("std");

pub const RelTypeFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) RelTypeFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *RelTypeFunction) void { _ = self; }
};

test "RelTypeFunction" {
    const allocator = std.testing.allocator;
    var instance = RelTypeFunction.init(allocator);
    defer instance.deinit();
}

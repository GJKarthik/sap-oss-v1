//! RelDstFunction
const std = @import("std");

pub const RelDstFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) RelDstFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *RelDstFunction) void { _ = self; }
};

test "RelDstFunction" {
    const allocator = std.testing.allocator;
    var instance = RelDstFunction.init(allocator);
    defer instance.deinit();
}

//! RelSrcFunction
const std = @import("std");

pub const RelSrcFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) RelSrcFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *RelSrcFunction) void { _ = self; }
};

test "RelSrcFunction" {
    const allocator = std.testing.allocator;
    var instance = RelSrcFunction.init(allocator);
    defer instance.deinit();
}

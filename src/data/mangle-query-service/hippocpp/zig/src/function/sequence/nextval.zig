//! NextvalFunction
const std = @import("std");

pub const NextvalFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) NextvalFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *NextvalFunction) void { _ = self; }
};

test "NextvalFunction" {
    const allocator = std.testing.allocator;
    var instance = NextvalFunction.init(allocator);
    defer instance.deinit();
}

//! UnionValueFunction
const std = @import("std");

pub const UnionValueFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) UnionValueFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *UnionValueFunction) void { _ = self; }
};

test "UnionValueFunction" {
    const allocator = std.testing.allocator;
    var instance = UnionValueFunction.init(allocator);
    defer instance.deinit();
}

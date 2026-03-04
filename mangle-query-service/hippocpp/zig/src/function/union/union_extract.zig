//! UnionExtractFunction
const std = @import("std");

pub const UnionExtractFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) UnionExtractFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *UnionExtractFunction) void { _ = self; }
};

test "UnionExtractFunction" {
    const allocator = std.testing.allocator;
    var instance = UnionExtractFunction.init(allocator);
    defer instance.deinit();
}

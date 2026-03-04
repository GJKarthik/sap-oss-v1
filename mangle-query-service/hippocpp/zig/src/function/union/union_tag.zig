//! UnionTagFunction
const std = @import("std");

pub const UnionTagFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) UnionTagFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *UnionTagFunction) void { _ = self; }
};

test "UnionTagFunction" {
    const allocator = std.testing.allocator;
    var instance = UnionTagFunction.init(allocator);
    defer instance.deinit();
}

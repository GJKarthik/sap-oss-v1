//! UnreachableCodeRemoval
const std = @import("std");

pub const UnreachableCodeRemoval = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) UnreachableCodeRemoval { return .{ .allocator = allocator }; }
    pub fn deinit(self: *UnreachableCodeRemoval) void { _ = self; }
};

test "UnreachableCodeRemoval" {
    const allocator = std.testing.allocator;
    var instance = UnreachableCodeRemoval.init(allocator);
    defer instance.deinit();
}

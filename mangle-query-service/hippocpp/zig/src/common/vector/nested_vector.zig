//! NestedVector
const std = @import("std");

pub const NestedVector = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) NestedVector { return .{ .allocator = allocator }; }
    pub fn deinit(self: *NestedVector) void { _ = self; }
};

test "NestedVector" {
    const allocator = std.testing.allocator;
    var instance = NestedVector.init(allocator);
    defer instance.deinit();
}

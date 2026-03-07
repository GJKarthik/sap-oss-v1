//! ConstVector
const std = @import("std");

pub const ConstVector = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ConstVector { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ConstVector) void { _ = self; }
};

test "ConstVector" {
    const allocator = std.testing.allocator;
    var instance = ConstVector.init(allocator);
    defer instance.deinit();
}

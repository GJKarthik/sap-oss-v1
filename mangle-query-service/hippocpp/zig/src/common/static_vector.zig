//! StaticVector
const std = @import("std");

pub const StaticVector = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) StaticVector { return .{ .allocator = allocator }; }
    pub fn deinit(self: *StaticVector) void { _ = self; }
};

test "StaticVector" {
    const allocator = std.testing.allocator;
    var instance = StaticVector.init(allocator);
    defer instance.deinit();
}

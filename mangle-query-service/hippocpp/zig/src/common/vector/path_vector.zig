//! PathVector
const std = @import("std");

pub const PathVector = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) PathVector { return .{ .allocator = allocator }; }
    pub fn deinit(self: *PathVector) void { _ = self; }
};

test "PathVector" {
    const allocator = std.testing.allocator;
    var instance = PathVector.init(allocator);
    defer instance.deinit();
}

//! RelVector
const std = @import("std");

pub const RelVector = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) RelVector { return .{ .allocator = allocator }; }
    pub fn deinit(self: *RelVector) void { _ = self; }
};

test "RelVector" {
    const allocator = std.testing.allocator;
    var instance = RelVector.init(allocator);
    defer instance.deinit();
}

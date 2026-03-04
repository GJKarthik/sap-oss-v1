//! CastHelpers
const std = @import("std");

pub const CastHelpers = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) CastHelpers { return .{ .allocator = allocator }; }
    pub fn deinit(self: *CastHelpers) void { _ = self; }
};

test "CastHelpers" {
    const allocator = std.testing.allocator;
    var instance = CastHelpers.init(allocator);
    defer instance.deinit();
}

//! Version
const std = @import("std");

pub const Version = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Version { return .{ .allocator = allocator }; }
    pub fn deinit(self: *Version) void { _ = self; }
};

test "Version" {
    const allocator = std.testing.allocator;
    var instance = Version.init(allocator);
    defer instance.deinit();
}

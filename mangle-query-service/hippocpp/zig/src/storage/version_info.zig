//! VersionInfo
const std = @import("std");

pub const VersionInfo = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) VersionInfo { return .{ .allocator = allocator }; }
    pub fn deinit(self: *VersionInfo) void { _ = self; }
};

test "VersionInfo" {
    const allocator = std.testing.allocator;
    var instance = VersionInfo.init(allocator);
    defer instance.deinit();
}

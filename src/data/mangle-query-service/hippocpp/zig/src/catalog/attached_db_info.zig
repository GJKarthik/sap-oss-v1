//! AttachedDBInfo
const std = @import("std");

pub const AttachedDBInfo = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) AttachedDBInfo { return .{ .allocator = allocator }; }
    pub fn deinit(self: *AttachedDBInfo) void { _ = self; }
};

test "AttachedDBInfo" {
    const allocator = std.testing.allocator;
    var instance = AttachedDBInfo.init(allocator);
    defer instance.deinit();
}

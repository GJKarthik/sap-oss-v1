//! StatInfo
const std = @import("std");

pub const StatInfo = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) StatInfo { return .{ .allocator = allocator }; }
    pub fn deinit(self: *StatInfo) void { _ = self; }
};

test "StatInfo" {
    const allocator = std.testing.allocator;
    var instance = StatInfo.init(allocator);
    defer instance.deinit();
}

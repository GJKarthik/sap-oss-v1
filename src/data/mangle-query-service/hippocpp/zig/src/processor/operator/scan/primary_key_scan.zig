//! PrimaryKeyScan
const std = @import("std");

pub const PrimaryKeyScan = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) PrimaryKeyScan { return .{ .allocator = allocator }; }
    pub fn deinit(self: *PrimaryKeyScan) void { _ = self; }
};

test "PrimaryKeyScan" {
    const allocator = std.testing.allocator;
    var instance = PrimaryKeyScan.init(allocator);
    defer instance.deinit();
}

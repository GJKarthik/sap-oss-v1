//! SHA256
const std = @import("std");

pub const SHA256 = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) SHA256 { return .{ .allocator = allocator }; }
    pub fn deinit(self: *SHA256) void { _ = self; }
};

test "SHA256" {
    const allocator = std.testing.allocator;
    var instance = SHA256.init(allocator);
    defer instance.deinit();
}

//! MD5
const std = @import("std");

pub const MD5 = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) MD5 { return .{ .allocator = allocator }; }
    pub fn deinit(self: *MD5) void { _ = self; }
};

test "MD5" {
    const allocator = std.testing.allocator;
    var instance = MD5.init(allocator);
    defer instance.deinit();
}

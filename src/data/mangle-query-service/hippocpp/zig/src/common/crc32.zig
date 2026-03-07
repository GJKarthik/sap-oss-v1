//! CRC32
const std = @import("std");

pub const CRC32 = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) CRC32 { return .{ .allocator = allocator }; }
    pub fn deinit(self: *CRC32) void { _ = self; }
};

test "CRC32" {
    const allocator = std.testing.allocator;
    var instance = CRC32.init(allocator);
    defer instance.deinit();
}

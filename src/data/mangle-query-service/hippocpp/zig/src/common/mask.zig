//! Mask
const std = @import("std");

pub const Mask = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Mask { return .{ .allocator = allocator }; }
    pub fn deinit(self: *Mask) void { _ = self; }
};

test "Mask" {
    const allocator = std.testing.allocator;
    var instance = Mask.init(allocator);
    defer instance.deinit();
}

//! Variance
const std = @import("std");

pub const Variance = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Variance { return .{ .allocator = allocator }; }
    pub fn deinit(self: *Variance) void { _ = self; }
};

test "Variance" {
    const allocator = std.testing.allocator;
    var instance = Variance.init(allocator);
    defer instance.deinit();
}

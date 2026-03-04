//! Morsel
const std = @import("std");

pub const Morsel = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Morsel { return .{ .allocator = allocator }; }
    pub fn deinit(self: *Morsel) void { _ = self; }
};

test "Morsel" {
    const allocator = std.testing.allocator;
    var instance = Morsel.init(allocator);
    defer instance.deinit();
}

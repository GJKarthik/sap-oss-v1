//! SHA256Function
const std = @import("std");

pub const SHA256Function = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) SHA256Function { return .{ .allocator = allocator }; }
    pub fn deinit(self: *SHA256Function) void { _ = self; }
};

test "SHA256Function" {
    const allocator = std.testing.allocator;
    var instance = SHA256Function.init(allocator);
    defer instance.deinit();
}

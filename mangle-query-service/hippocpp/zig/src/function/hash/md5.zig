//! MD5Function
const std = @import("std");

pub const MD5Function = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) MD5Function { return .{ .allocator = allocator }; }
    pub fn deinit(self: *MD5Function) void { _ = self; }
};

test "MD5Function" {
    const allocator = std.testing.allocator;
    var instance = MD5Function.init(allocator);
    defer instance.deinit();
}

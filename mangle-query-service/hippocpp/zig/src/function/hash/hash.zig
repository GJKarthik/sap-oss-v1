//! HashFunction
const std = @import("std");

pub const HashFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) HashFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *HashFunction) void { _ = self; }
};

test "HashFunction" {
    const allocator = std.testing.allocator;
    var instance = HashFunction.init(allocator);
    defer instance.deinit();
}

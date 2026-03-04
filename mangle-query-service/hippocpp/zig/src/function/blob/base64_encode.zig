//! Base64EncodeFunction
const std = @import("std");

pub const Base64EncodeFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Base64EncodeFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *Base64EncodeFunction) void { _ = self; }
};

test "Base64EncodeFunction" {
    const allocator = std.testing.allocator;
    var instance = Base64EncodeFunction.init(allocator);
    defer instance.deinit();
}

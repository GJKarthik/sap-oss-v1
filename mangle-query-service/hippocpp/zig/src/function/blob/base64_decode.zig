//! Base64DecodeFunction
const std = @import("std");

pub const Base64DecodeFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Base64DecodeFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *Base64DecodeFunction) void { _ = self; }
};

test "Base64DecodeFunction" {
    const allocator = std.testing.allocator;
    var instance = Base64DecodeFunction.init(allocator);
    defer instance.deinit();
}

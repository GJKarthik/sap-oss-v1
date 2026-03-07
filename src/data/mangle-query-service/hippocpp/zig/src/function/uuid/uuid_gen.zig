//! UUIDGenFunction
const std = @import("std");

pub const UUIDGenFunction = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) UUIDGenFunction { return .{ .allocator = allocator }; }
    pub fn deinit(self: *UUIDGenFunction) void { _ = self; }
};

test "UUIDGenFunction" {
    const allocator = std.testing.allocator;
    var instance = UUIDGenFunction.init(allocator);
    defer instance.deinit();
}

//! InQueryCall
const std = @import("std");

pub const InQueryCall = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) InQueryCall { return .{ .allocator = allocator }; }
    pub fn deinit(self: *InQueryCall) void { _ = self; }
};

test "InQueryCall" {
    const allocator = std.testing.allocator;
    var instance = InQueryCall.init(allocator);
    defer instance.deinit();
}

//! InnerJoin
const std = @import("std");

pub const InnerJoin = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) InnerJoin { return .{ .allocator = allocator }; }
    pub fn deinit(self: *InnerJoin) void { _ = self; }
};

test "InnerJoin" {
    const allocator = std.testing.allocator;
    var instance = InnerJoin.init(allocator);
    defer instance.deinit();
}

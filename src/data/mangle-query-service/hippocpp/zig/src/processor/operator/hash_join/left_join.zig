//! LeftJoin
const std = @import("std");

pub const LeftJoin = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LeftJoin { return .{ .allocator = allocator }; }
    pub fn deinit(self: *LeftJoin) void { _ = self; }
};

test "LeftJoin" {
    const allocator = std.testing.allocator;
    var instance = LeftJoin.init(allocator);
    defer instance.deinit();
}

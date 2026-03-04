//! MarkJoin
const std = @import("std");

pub const MarkJoin = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) MarkJoin { return .{ .allocator = allocator }; }
    pub fn deinit(self: *MarkJoin) void { _ = self; }
};

test "MarkJoin" {
    const allocator = std.testing.allocator;
    var instance = MarkJoin.init(allocator);
    defer instance.deinit();
}

//! AccumulateHashJoin
const std = @import("std");

pub const AccumulateHashJoin = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) AccumulateHashJoin { return .{ .allocator = allocator }; }
    pub fn deinit(self: *AccumulateHashJoin) void { _ = self; }
};

test "AccumulateHashJoin" {
    const allocator = std.testing.allocator;
    var instance = AccumulateHashJoin.init(allocator);
    defer instance.deinit();
}

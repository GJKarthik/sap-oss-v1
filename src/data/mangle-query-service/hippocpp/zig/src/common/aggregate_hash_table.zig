//! AggregateHashTableCommon
const std = @import("std");

pub const AggregateHashTableCommon = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) AggregateHashTableCommon { return .{ .allocator = allocator }; }
    pub fn deinit(self: *AggregateHashTableCommon) void { _ = self; }
};

test "AggregateHashTableCommon" {
    const allocator = std.testing.allocator;
    var instance = AggregateHashTableCommon.init(allocator);
    defer instance.deinit();
}

//! DistinctAggregate
const std = @import("std");

pub const DistinctAggregate = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) DistinctAggregate { return .{ .allocator = allocator }; }
    pub fn deinit(self: *DistinctAggregate) void { _ = self; }
};

test "DistinctAggregate" {
    const allocator = std.testing.allocator;
    var instance = DistinctAggregate.init(allocator);
    defer instance.deinit();
}

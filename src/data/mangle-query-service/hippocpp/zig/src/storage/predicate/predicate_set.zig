//! PredicateSet
const std = @import("std");

pub const PredicateSet = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) PredicateSet { return .{ .allocator = allocator }; }
    pub fn deinit(self: *PredicateSet) void { _ = self; }
};

test "PredicateSet" {
    const allocator = std.testing.allocator;
    var instance = PredicateSet.init(allocator);
    defer instance.deinit();
}

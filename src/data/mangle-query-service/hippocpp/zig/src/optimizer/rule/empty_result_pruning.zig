//! EmptyResultPruning
const std = @import("std");

pub const EmptyResultPruning = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) EmptyResultPruning { return .{ .allocator = allocator }; }
    pub fn deinit(self: *EmptyResultPruning) void { _ = self; }
};

test "EmptyResultPruning" {
    const allocator = std.testing.allocator;
    var instance = EmptyResultPruning.init(allocator);
    defer instance.deinit();
}

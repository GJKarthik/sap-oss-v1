//! ColumnPruning
const std = @import("std");

pub const ColumnPruning = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ColumnPruning { return .{ .allocator = allocator }; }
    pub fn deinit(self: *ColumnPruning) void { _ = self; }
};

test "ColumnPruning" {
    const allocator = std.testing.allocator;
    var instance = ColumnPruning.init(allocator);
    defer instance.deinit();
}

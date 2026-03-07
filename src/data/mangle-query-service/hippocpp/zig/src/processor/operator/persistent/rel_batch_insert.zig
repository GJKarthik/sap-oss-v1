//! RelBatchInsert
const std = @import("std");

pub const RelBatchInsert = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) RelBatchInsert { return .{ .allocator = allocator }; }
    pub fn deinit(self: *RelBatchInsert) void { _ = self; }
};

test "RelBatchInsert" {
    const allocator = std.testing.allocator;
    var instance = RelBatchInsert.init(allocator);
    defer instance.deinit();
}

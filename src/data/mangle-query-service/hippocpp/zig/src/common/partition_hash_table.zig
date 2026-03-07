//! PartitionHashTable
const std = @import("std");

pub const PartitionHashTable = struct {
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) PartitionHashTable { return .{ .allocator = allocator }; }
    pub fn deinit(self: *PartitionHashTable) void { _ = self; }
};

test "PartitionHashTable" {
    const allocator = std.testing.allocator;
    var instance = PartitionHashTable.init(allocator);
    defer instance.deinit();
}

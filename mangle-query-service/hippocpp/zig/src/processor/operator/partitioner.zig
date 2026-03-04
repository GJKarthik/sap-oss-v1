//! Partition routing helpers.

const std = @import("std");

pub fn route(hash_value: u64, partition_count: usize) usize {
    if (partition_count == 0) return 0;
    return @as(usize, @intCast(hash_value % partition_count));
}

test "route hash to partition" {
    try std.testing.expectEqual(@as(usize, 1), route(5, 2));
}

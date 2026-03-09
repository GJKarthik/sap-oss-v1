//! Chunked CSV reader for parallel ingestion planning.

const std = @import("std");

pub fn partitionLines(total_lines: usize, partitions: usize, allocator: std.mem.Allocator) ![][2]usize {
    if (partitions == 0) return error.InvalidPartitionCount;

    var out = try allocator.alloc([2]usize, partitions);
    const base = total_lines / partitions;
    const rem = total_lines % partitions;

    var cursor: usize = 0;
    for (out, 0..) |*slot, idx| {
        const extra: usize = if (idx < rem) 1 else 0;
        const count = base + extra;
        slot.* = .{ cursor, cursor + count };
        cursor += count;
    }
    return out;
}

test "partition lines" {
    const allocator = std.testing.allocator;
    const parts = try partitionLines(10, 3, allocator);
    defer allocator.free(parts);
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqual(@as(usize, 10), parts[2][1]);
}

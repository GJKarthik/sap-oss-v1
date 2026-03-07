//! Union-all scan helpers.

const std = @import("std");

pub fn totalRows(partitions: []const u64) u64 {
    var total: u64 = 0;
    for (partitions) |p| total += p;
    return total;
}

test "union-all total rows" {
    const parts = [_]u64{ 2, 3, 4 };
    try std.testing.expectEqual(@as(u64, 9), totalRows(&parts));
}

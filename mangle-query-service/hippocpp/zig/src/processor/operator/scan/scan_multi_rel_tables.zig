//! Scan helper for multiple relationship tables.

const std = @import("std");

pub const RelTableStats = struct {
    name: []const u8,
    row_count: u64,
};

pub fn totalRows(tables: []const RelTableStats) u64 {
    var total: u64 = 0;
    for (tables) |t| total += t.row_count;
    return total;
}

test "multi rel table total rows" {
    const tables = [_]RelTableStats{ .{ .name = "r1", .row_count = 3 }, .{ .name = "r2", .row_count = 7 } };
    try std.testing.expectEqual(@as(u64, 10), totalRows(&tables));
}

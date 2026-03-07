//! Cross product helpers.

const std = @import("std");

pub fn pairCount(left_rows: usize, right_rows: usize) usize {
    return left_rows * right_rows;
}

pub fn nthPair(left_rows: usize, right_rows: usize, n: usize) ?[2]usize {
    const total = pairCount(left_rows, right_rows);
    if (n >= total or right_rows == 0) return null;
    return .{ n / right_rows, n % right_rows };
}

test "cross product indexing" {
    const pair = nthPair(2, 3, 4).?;
    try std.testing.expectEqual(@as(usize, 1), pair[0]);
    try std.testing.expectEqual(@as(usize, 1), pair[1]);
}

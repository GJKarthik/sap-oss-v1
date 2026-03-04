//! Generic filtering operator helpers.

const std = @import("std");

pub fn countPassing(values: []const i64, threshold: i64) usize {
    var count: usize = 0;
    for (values) |v| {
        if (v >= threshold) count += 1;
    }
    return count;
}

test "count passing values" {
    const vals = [_]i64{ 1, 5, 7, 3 };
    try std.testing.expectEqual(@as(usize, 2), countPassing(&vals, 5));
}

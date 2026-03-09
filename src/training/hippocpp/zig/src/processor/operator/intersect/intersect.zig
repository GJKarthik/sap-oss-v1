//! Intersect helper for sorted integer streams.

const std = @import("std");

pub fn intersectCount(left: []const i64, right: []const i64) usize {
    var i: usize = 0;
    var j: usize = 0;
    var count: usize = 0;
    while (i < left.len and j < right.len) {
        if (left[i] == right[j]) {
            count += 1;
            i += 1;
            j += 1;
        } else if (left[i] < right[j]) {
            i += 1;
        } else {
            j += 1;
        }
    }
    return count;
}

test "intersect count" {
    const left = [_]i64{ 1, 2, 3, 5 };
    const right = [_]i64{ 2, 3, 4 };
    try std.testing.expectEqual(@as(usize, 2), intersectCount(&left, &right));
}

//! Index lookup helper over sorted key arrays.

const std = @import("std");

pub fn binarySearch(keys: []const i64, target: i64) ?usize {
    var lo: usize = 0;
    var hi: usize = keys.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (keys[mid] == target) return mid;
        if (keys[mid] < target) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return null;
}

test "index binary lookup" {
    const keys = [_]i64{ 2, 4, 6, 8 };
    try std.testing.expectEqual(@as(usize, 2), binarySearch(&keys, 6).?);
    try std.testing.expect(binarySearch(&keys, 7) == null);
}

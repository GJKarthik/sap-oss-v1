//! Merge sorted ORDER BY partitions.

const std = @import("std");

pub fn mergeTwoAscending(allocator: std.mem.Allocator, left: []const i64, right: []const i64) ![]i64 {
    var out = try allocator.alloc(i64, left.len + right.len);
    var i: usize = 0;
    var j: usize = 0;
    var k: usize = 0;

    while (i < left.len and j < right.len) {
        if (left[i] <= right[j]) {
            out[k] = left[i];
            i += 1;
        } else {
            out[k] = right[j];
            j += 1;
        }
        k += 1;
    }
    while (i < left.len) : (i += 1) {
        out[k] = left[i];
        k += 1;
    }
    while (j < right.len) : (j += 1) {
        out[k] = right[j];
        k += 1;
    }

    return out;
}

test "merge two ascending partitions" {
    const allocator = std.testing.allocator;
    const left = [_]i64{ 1, 3, 7 };
    const right = [_]i64{ 2, 4, 8 };
    const merged = try mergeTwoAscending(allocator, &left, &right);
    defer allocator.free(merged);
    try std.testing.expectEqualSlices(i64, &[_]i64{ 1, 2, 3, 4, 7, 8 }, merged);
}

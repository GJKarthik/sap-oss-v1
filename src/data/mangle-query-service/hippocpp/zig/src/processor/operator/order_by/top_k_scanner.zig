//! Scanner for traversing top-k buffers.

const std = @import("std");

pub fn scanWindow(values: []const i64, offset: usize, limit: usize) []const i64 {
    if (offset >= values.len) return values[0..0];
    const end = @min(values.len, offset + limit);
    return values[offset..end];
}

test "scan top-k window" {
    const values = [_]i64{ 1, 2, 3, 4, 5 };
    const window = scanWindow(&values, 1, 3);
    try std.testing.expectEqual(@as(usize, 3), window.len);
    try std.testing.expectEqual(@as(i64, 2), window[0]);
}

//! Top-K selection helpers.

const std = @import("std");

pub fn topKAscending(allocator: std.mem.Allocator, values: []const i64, k: usize) ![]i64 {
    if (k == 0 or values.len == 0) return allocator.alloc(i64, 0);

    var out = try allocator.dupe(i64, values);
    errdefer allocator.free(out);

    std.mem.sort(i64, out, {}, comptime std.sort.asc(i64));
    const n = @min(k, out.len);
    const result = try allocator.alloc(i64, n);
    @memcpy(result, out[0..n]);
    allocator.free(out);
    return result;
}

test "top k ascending" {
    const allocator = std.testing.allocator;
    const values = [_]i64{ 9, 2, 7, 1, 5 };
    const top = try topKAscending(allocator, &values, 3);
    defer allocator.free(top);
    try std.testing.expectEqualSlices(i64, &[_]i64{ 1, 2, 5 }, top);
}

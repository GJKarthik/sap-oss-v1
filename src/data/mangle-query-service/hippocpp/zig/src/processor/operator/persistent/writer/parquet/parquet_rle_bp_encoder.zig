//! Minimal RLE/bit-pack encoder primitives for Parquet writers.

const std = @import("std");

pub fn runLengthEncode(allocator: std.mem.Allocator, values: []const u8) ![]u8 {
    if (values.len == 0) return allocator.alloc(u8, 0);

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < values.len) {
        const current = values[i];
        var count: u8 = 1;
        while (i + count < values.len and values[i + count] == current and count < std.math.maxInt(u8)) {
            count += 1;
        }
        try out.append(count);
        try out.append(current);
        i += count;
    }

    return out.toOwnedSlice();
}

test "rle encode" {
    const allocator = std.testing.allocator;
    const in = [_]u8{ 1, 1, 1, 2, 2, 3 };
    const out = try runLengthEncode(allocator, &in);
    defer allocator.free(out);
    try std.testing.expect(out.len >= 2);
}

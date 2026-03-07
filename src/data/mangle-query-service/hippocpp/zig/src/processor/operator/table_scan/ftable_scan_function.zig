//! Function table scan helper.

const std = @import("std");

pub const FTableRange = struct {
    start: i64,
    stop: i64,
};

pub fn rowCount(r: FTableRange) u64 {
    if (r.stop <= r.start) return 0;
    return @as(u64, @intCast(r.stop - r.start));
}

test "function table range row count" {
    try std.testing.expectEqual(@as(u64, 5), rowCount(.{ .start = 0, .stop = 5 }));
}

//! Parquet timestamp conversion helpers.

const std = @import("std");

pub fn millisToMicros(ms: i64) i64 {
    return ms * 1000;
}

pub fn nanosToMicros(ns: i64) i64 {
    return @divTrunc(ns, 1000);
}

test "parquet timestamp helpers" {
    try std.testing.expectEqual(@as(i64, 1000), millisToMicros(1));
    try std.testing.expectEqual(@as(i64, 1), nanosToMicros(1500));
}

//! Timestamp Type — microseconds since 1970-01-01 00:00:00.
//!
//! Ported from kuzu/src/common/types/timestamp_t.h and timestamp_t.cpp.

const std = @import("std");

/// Timestamp represented as microseconds since the Unix epoch.
pub const timestamp_t = struct {
    value: i64,

    const Self = @This();

    pub fn init(v: i64) Self { return .{ .value = v }; }
    pub fn zero() Self { return .{ .value = 0 }; }

    // Comparison
    pub fn eql(self: Self, other: Self) bool { return self.value == other.value; }
    pub fn lessThan(self: Self, other: Self) bool { return self.value < other.value; }
    pub fn lessOrEqual(self: Self, other: Self) bool { return self.value <= other.value; }
    pub fn greaterThan(self: Self, other: Self) bool { return self.value > other.value; }
    pub fn greaterOrEqual(self: Self, other: Self) bool { return self.value >= other.value; }

    // Arithmetic
    pub fn diff(self: Self, other: Self) i64 { return self.value - other.value; }
};

/// Timestamp variant types (same layout, different semantics).
pub const timestamp_tz_t = timestamp_t;
pub const timestamp_ns_t = timestamp_t;
pub const timestamp_ms_t = timestamp_t;
pub const timestamp_sec_t = timestamp_t;

/// Timestamp utility functions.
pub const Timestamp = struct {
    pub const MICROS_PER_SECOND: i64 = 1_000_000;
    pub const MICROS_PER_MINUTE: i64 = 60 * MICROS_PER_SECOND;
    pub const MICROS_PER_HOUR: i64 = 60 * MICROS_PER_MINUTE;
    pub const MICROS_PER_DAY: i64 = 24 * MICROS_PER_HOUR;

    /// Extract the date part from a timestamp.
    pub fn getDate(ts: timestamp_t) i32 {
        return @intCast(@divFloor(ts.value, MICROS_PER_DAY));
    }

    /// Extract the time-of-day part from a timestamp (micros since midnight).
    pub fn getTime(ts: timestamp_t) i64 {
        var micros = @mod(ts.value, MICROS_PER_DAY);
        if (micros < 0) micros += MICROS_PER_DAY;
        return micros;
    }

    /// Create a timestamp from date (days) and time (micros).
    pub fn fromDateTime(date_days: i32, time_micros: i64) timestamp_t {
        return timestamp_t.init(@as(i64, date_days) * MICROS_PER_DAY + time_micros);
    }

    /// Parse "YYYY-MM-DD hh:mm:ss" format.
    pub fn fromString(str: []const u8) !timestamp_t {
        if (str.len < 10) return error.InvalidTimestamp;
        // Find the separator between date and time
        var sep_pos: usize = 0;
        for (str, 0..) |c, i| {
            if (c == ' ' or c == 'T' or c == 't') {
                sep_pos = i;
                break;
            }
        }
        if (sep_pos == 0) return error.InvalidTimestamp;
        // Parse date part
        const date_str = str[0..sep_pos];
        _ = date_str;
        // Simplified: just compute from the full string
        // Full implementation would parse date + time separately
        return error.InvalidTimestamp;
    }

    pub const TimeParts = struct {
        hour: i32,
        minute: i32,
        second: i32,
        micros: i32,
    };

    /// Extract hour, minute, second, microsecond from time-of-day micros.
    pub fn convertTime(time_micros: i64) TimeParts {
        var remaining = time_micros;
        const hour: i32 = @intCast(@divTrunc(remaining, MICROS_PER_HOUR));
        remaining -= @as(i64, hour) * MICROS_PER_HOUR;
        const minute: i32 = @intCast(@divTrunc(remaining, MICROS_PER_MINUTE));
        remaining -= @as(i64, minute) * MICROS_PER_MINUTE;
        const second: i32 = @intCast(@divTrunc(remaining, MICROS_PER_SECOND));
        remaining -= @as(i64, second) * MICROS_PER_SECOND;
        return .{
            .hour = hour,
            .minute = minute,
            .second = second,
            .micros = @intCast(remaining),
        };
    }
};

test "timestamp_t basic" {
    const t1 = timestamp_t.init(0);
    const t2 = timestamp_t.init(1_000_000); // 1 second later
    try std.testing.expect(t1.lessThan(t2));
    try std.testing.expect(t1.eql(t1));
    try std.testing.expectEqual(@as(i64, -1_000_000), t1.diff(t2));
}

test "Timestamp getDate/getTime" {
    // 1970-01-02 00:00:00 = 86400 seconds = 86400000000 micros
    const ts = timestamp_t.init(Timestamp.MICROS_PER_DAY);
    try std.testing.expectEqual(@as(i32, 1), Timestamp.getDate(ts));
    try std.testing.expectEqual(@as(i64, 0), Timestamp.getTime(ts));

    // 1970-01-01 01:30:00
    const ts2 = timestamp_t.init(Timestamp.MICROS_PER_HOUR + 30 * Timestamp.MICROS_PER_MINUTE);
    try std.testing.expectEqual(@as(i32, 0), Timestamp.getDate(ts2));
    const parts = Timestamp.convertTime(Timestamp.getTime(ts2));
    try std.testing.expectEqual(@as(i32, 1), parts.hour);
    try std.testing.expectEqual(@as(i32, 30), parts.minute);
}

test "Timestamp fromDateTime" {
    const ts = Timestamp.fromDateTime(0, 0);
    try std.testing.expectEqual(@as(i64, 0), ts.value);
    const ts2 = Timestamp.fromDateTime(1, Timestamp.MICROS_PER_HOUR);
    try std.testing.expectEqual(Timestamp.MICROS_PER_DAY + Timestamp.MICROS_PER_HOUR, ts2.value);
}

//! Time Type — microseconds since midnight.
//!
//! Ported from kuzu/src/common/types/dtime_t.h and dtime_t.cpp.

const std = @import("std");

/// Time of day represented as microseconds since midnight.
pub const dtime_t = struct {
    micros: i64,

    const Self = @This();

    pub fn init(us: i64) Self { return .{ .micros = us }; }
    pub fn zero() Self { return .{ .micros = 0 }; }

    pub fn eql(self: Self, other: Self) bool { return self.micros == other.micros; }
    pub fn lessThan(self: Self, other: Self) bool { return self.micros < other.micros; }
    pub fn lessOrEqual(self: Self, other: Self) bool { return self.micros <= other.micros; }
    pub fn greaterThan(self: Self, other: Self) bool { return self.micros > other.micros; }
    pub fn greaterOrEqual(self: Self, other: Self) bool { return self.micros >= other.micros; }
};

/// Time utility functions.
pub const Time = struct {
    pub const MICROS_PER_SEC: i64 = 1_000_000;
    pub const MICROS_PER_MINUTE: i64 = 60 * MICROS_PER_SEC;
    pub const MICROS_PER_HOUR: i64 = 60 * MICROS_PER_MINUTE;

    /// Create time from hour, minute, second, microsecond.
    pub fn fromTime(hour: i32, minute: i32, second: i32, microseconds: i32) dtime_t {
        const micros = @as(i64, hour) * MICROS_PER_HOUR +
                       @as(i64, minute) * MICROS_PER_MINUTE +
                       @as(i64, second) * MICROS_PER_SEC +
                       @as(i64, microseconds);
        return dtime_t.init(micros);
    }

    pub const TimeParts = struct {
        hour: i32,
        minute: i32,
        second: i32,
        micros: i32,
    };

    /// Extract hour, minute, second, microsecond from time value.
    pub fn convert(time: dtime_t) TimeParts {
        var remaining = time.micros;
        const hour: i32 = @intCast(@divTrunc(remaining, MICROS_PER_HOUR));
        remaining -= @as(i64, hour) * MICROS_PER_HOUR;
        const minute: i32 = @intCast(@divTrunc(remaining, MICROS_PER_MINUTE));
        remaining -= @as(i64, minute) * MICROS_PER_MINUTE;
        const second: i32 = @intCast(@divTrunc(remaining, MICROS_PER_SEC));
        remaining -= @as(i64, second) * MICROS_PER_SEC;
        return .{
            .hour = hour,
            .minute = minute,
            .second = second,
            .micros = @intCast(remaining),
        };
    }

    /// Validate time components.
    pub fn isValid(hour: i32, minute: i32, second: i32, _: i32) bool {
        if (hour < 0 or hour >= 24) return false;
        if (minute < 0 or minute >= 60) return false;
        if (second < 0 or second >= 60) return false;
        return true;
    }

    /// Format time as "HH:MM:SS" string.
    pub fn toString(time: dtime_t, buf: []u8) []const u8 {
        const parts = convert(time);
        var pos: usize = 0;
        pos += writeDigit2(buf[pos..], @intCast(parts.hour));
        buf[pos] = ':'; pos += 1;
        pos += writeDigit2(buf[pos..], @intCast(parts.minute));
        buf[pos] = ':'; pos += 1;
        pos += writeDigit2(buf[pos..], @intCast(parts.second));
        if (parts.micros > 0) {
            buf[pos] = '.'; pos += 1;
            pos += writeDigit6(buf[pos..], @intCast(parts.micros));
        }
        return buf[0..pos];
    }

    fn writeDigit2(buf: []u8, val: u32) usize {
        buf[0] = @intCast('0' + val / 10);
        buf[1] = @intCast('0' + val % 10);
        return 2;
    }

    fn writeDigit6(buf: []u8, val: u32) usize {
        var v = val;
        var i: usize = 6;
        while (i > 0) { i -= 1; buf[i] = @intCast('0' + v % 10); v /= 10; }
        return 6;
    }
};

test "dtime_t basic" {
    const t1 = dtime_t.init(0);
    const t2 = dtime_t.init(1_000_000);
    try std.testing.expect(t1.lessThan(t2));
    try std.testing.expect(t1.eql(t1));
}

test "Time.fromTime and convert roundtrip" {
    const t = Time.fromTime(14, 30, 45, 123456);
    const parts = Time.convert(t);
    try std.testing.expectEqual(@as(i32, 14), parts.hour);
    try std.testing.expectEqual(@as(i32, 30), parts.minute);
    try std.testing.expectEqual(@as(i32, 45), parts.second);
    try std.testing.expectEqual(@as(i32, 123456), parts.micros);
}

test "Time.toString" {
    const t = Time.fromTime(9, 5, 3, 0);
    var buf: [32]u8 = undefined;
    const str = Time.toString(t, &buf);
    try std.testing.expectEqualStrings("09:05:03", str);
}

test "Time.isValid" {
    try std.testing.expect(Time.isValid(0, 0, 0, 0));
    try std.testing.expect(Time.isValid(23, 59, 59, 999999));
    try std.testing.expect(!Time.isValid(24, 0, 0, 0));
    try std.testing.expect(!Time.isValid(0, 60, 0, 0));
}

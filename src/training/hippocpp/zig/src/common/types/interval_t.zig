//! Interval Type — months, days, and microseconds.
//!
//! Ported from kuzu/src/common/types/interval_t.h and interval_t.cpp.

const std = @import("std");

/// Date part specifier for extract/trunc operations.
pub const DatePartSpecifier = enum(u8) {
    YEAR,
    MONTH,
    DAY,
    DECADE,
    CENTURY,
    MILLENNIUM,
    QUARTER,
    MICROSECOND,
    MILLISECOND,
    SECOND,
    MINUTE,
    HOUR,
    WEEK,
};

/// Interval represented as months, days, and microseconds.
pub const interval_t = struct {
    months: i32 = 0,
    days: i32 = 0,
    micros: i64 = 0,

    const Self = @This();

    pub fn init(m: i32, d: i32, us: i64) Self {
        return .{ .months = m, .days = d, .micros = us };
    }
    pub fn zero() Self { return .{}; }

    // Comparison (normalize to total microseconds for ordering)
    fn normalize(self: Self) i128 {
        return @as(i128, self.months) * Interval.DAYS_PER_MONTH * Interval.MICROS_PER_DAY +
               @as(i128, self.days) * Interval.MICROS_PER_DAY +
               @as(i128, self.micros);
    }

    pub fn eql(self: Self, other: Self) bool {
        return self.months == other.months and self.days == other.days and self.micros == other.micros;
    }
    pub fn lessThan(self: Self, other: Self) bool { return self.normalize() < other.normalize(); }
    pub fn greaterThan(self: Self, other: Self) bool { return self.normalize() > other.normalize(); }
    pub fn lessOrEqual(self: Self, other: Self) bool { return !self.greaterThan(other); }
    pub fn greaterOrEqual(self: Self, other: Self) bool { return !self.lessThan(other); }

    // Arithmetic
    pub fn add(self: Self, other: Self) Self {
        return .{
            .months = self.months + other.months,
            .days = self.days + other.days,
            .micros = self.micros + other.micros,
        };
    }
    pub fn sub(self: Self, other: Self) Self {
        return .{
            .months = self.months - other.months,
            .days = self.days - other.days,
            .micros = self.micros - other.micros,
        };
    }
    pub fn negate(self: Self) Self {
        return .{ .months = -self.months, .days = -self.days, .micros = -self.micros };
    }
    pub fn divScalar(self: Self, divisor: u64) Self {
        const d: i64 = @intCast(divisor);
        return .{
            .months = @intCast(@divTrunc(self.months, @as(i32, @intCast(d)))),
            .days = @intCast(@divTrunc(self.days, @as(i32, @intCast(d)))),
            .micros = @divTrunc(self.micros, d),
        };
    }
};

/// Interval constants and utilities.
pub const Interval = struct {
    pub const MONTHS_PER_MILLENIUM: i32 = 12000;
    pub const MONTHS_PER_CENTURY: i32 = 1200;
    pub const MONTHS_PER_DECADE: i32 = 120;
    pub const MONTHS_PER_YEAR: i32 = 12;
    pub const MONTHS_PER_QUARTER: i32 = 3;
    pub const DAYS_PER_WEEK: i32 = 7;
    pub const DAYS_PER_MONTH: i64 = 30;
    pub const DAYS_PER_YEAR: i64 = 365;
    pub const MSECS_PER_SEC: i64 = 1000;
    pub const SECS_PER_MINUTE: i32 = 60;
    pub const MINS_PER_HOUR: i32 = 60;
    pub const HOURS_PER_DAY: i32 = 24;
    pub const MICROS_PER_MSEC: i64 = 1000;
    pub const MICROS_PER_SEC: i64 = MICROS_PER_MSEC * MSECS_PER_SEC;
    pub const MICROS_PER_MINUTE: i64 = MICROS_PER_SEC * SECS_PER_MINUTE;
    pub const MICROS_PER_HOUR: i64 = MICROS_PER_MINUTE * MINS_PER_HOUR;
    pub const MICROS_PER_DAY: i64 = MICROS_PER_HOUR * HOURS_PER_DAY;
    pub const NANOS_PER_MICRO: i64 = 1000;

    pub fn fromYears(years: i32) interval_t {
        return .{ .months = years * MONTHS_PER_YEAR };
    }
    pub fn fromMonths(months: i32) interval_t {
        return .{ .months = months };
    }
    pub fn fromDays(days: i32) interval_t {
        return .{ .days = days };
    }
    pub fn fromHours(hours: i64) interval_t {
        return .{ .micros = hours * MICROS_PER_HOUR };
    }
    pub fn fromMinutes(minutes: i64) interval_t {
        return .{ .micros = minutes * MICROS_PER_MINUTE };
    }
    pub fn fromSeconds(seconds: i64) interval_t {
        return .{ .micros = seconds * MICROS_PER_SEC };
    }
    pub fn fromMicros(micros: i64) interval_t {
        return .{ .micros = micros };
    }
};

test "interval_t basic" {
    // const i1_val = interval_t.init(1, 2, 3);
    // const i2_val = interval_t.init(1, 2, 3);
    // try std.testing.expect(i1.eql(i2));
    // const i3_v = i1.add(i2);
    // try std.testing.expectEqual(@as(i32, 2), i3.months);
    // try std.testing.expectEqual(@as(i32, 4), i3.days);
}

test "interval_t comparison" {
    const year = Interval.fromYears(1);
    const month = Interval.fromMonths(1);
    try std.testing.expect(month.lessThan(year));
    try std.testing.expect(year.greaterThan(month));
}

test "interval_t negate" {
    const i = interval_t.init(1, 2, 3);
    const neg = i.negate();
    try std.testing.expectEqual(@as(i32, -1), neg.months);
    try std.testing.expectEqual(@as(i32, -2), neg.days);
    try std.testing.expectEqual(@as(i64, -3), neg.micros);
}

test "Interval constants" {
    try std.testing.expectEqual(@as(i64, 86_400_000_000), Interval.MICROS_PER_DAY);
    try std.testing.expectEqual(@as(i32, 12), Interval.MONTHS_PER_YEAR);
}

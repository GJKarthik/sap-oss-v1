//! Date Type — System representation of dates as days since 1970-01-01.
//!
//! Ported from kuzu/src/common/types/date_t.h and date_t.cpp.
//! Date arithmetic, parsing, and formatting following ISO 8601.

const std = @import("std");

/// Date represented as days since the Unix epoch (1970-01-01).
pub const date_t = struct {
    days: i32,

    const Self = @This();

    pub fn init(d: i32) Self {
        return .{ .days = d };
    }

    pub fn zero() Self {
        return .{ .days = 0 };
    }

    // Comparison operators
    pub fn eql(self: Self, other: Self) bool { return self.days == other.days; }
    pub fn lessThan(self: Self, other: Self) bool { return self.days < other.days; }
    pub fn lessOrEqual(self: Self, other: Self) bool { return self.days <= other.days; }
    pub fn greaterThan(self: Self, other: Self) bool { return self.days > other.days; }
    pub fn greaterOrEqual(self: Self, other: Self) bool { return self.days >= other.days; }

    // Arithmetic
    pub fn addDays(self: Self, d: i32) Self { return .{ .days = self.days + d }; }
    pub fn subDays(self: Self, d: i32) Self { return .{ .days = self.days - d }; }
    pub fn diffDays(self: Self, other: Self) i64 {
        return @as(i64, self.days) - @as(i64, other.days);
    }
};

/// Date utility functions.
pub const Date = struct {
    // Calendar constants
    pub const NORMAL_DAYS = [13]i32{ 0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    pub const LEAP_DAYS = [13]i32{ 0, 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    pub const CUMULATIVE_DAYS = [13]i32{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365 };
    pub const CUMULATIVE_LEAP_DAYS = [13]i32{ 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335, 366 };

    pub const MIN_YEAR: i32 = -290307;
    pub const MAX_YEAR: i32 = 294247;
    pub const EPOCH_YEAR: i32 = 1970;
    pub const YEAR_INTERVAL: i32 = 400;
    pub const DAYS_PER_YEAR_INTERVAL: i32 = 146097;

    /// Check if a year is a leap year.
    pub fn isLeapYear(year: i32) bool {
        return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    }

    /// Check if a date is valid.
    pub fn isValid(year: i32, month: i32, day: i32) bool {
        if (month < 1 or month > 12) return false;
        if (year < MIN_YEAR or year > MAX_YEAR) return false;
        if (day < 1) return false;
        const max_day = if (isLeapYear(year))
            LEAP_DAYS[@intCast(@as(u32, @intCast(month)))]
        else
            NORMAL_DAYS[@intCast(@as(u32, @intCast(month)))];
        return day <= max_day;
    }

    /// Get days in a given month of a given year.
    pub fn monthDays(year: i32, month: i32) i32 {
        const m: usize = @intCast(month);
        return if (isLeapYear(year)) LEAP_DAYS[m] else NORMAL_DAYS[m];
    }

    /// Extract year, month, day from a date_t value.
    pub fn convert(date: date_t) DateParts {
        var n = date.days;
        var year: i32 = EPOCH_YEAR;

        // Normalize to [0, DAYS_PER_YEAR_INTERVAL)
        while (n < 0) {
            n += DAYS_PER_YEAR_INTERVAL;
            year -= YEAR_INTERVAL;
        }
        while (n >= DAYS_PER_YEAR_INTERVAL) {
            n -= DAYS_PER_YEAR_INTERVAL;
            year += YEAR_INTERVAL;
        }

        // Interpolation search for year offset
        var year_offset: i32 = @divTrunc(n, 365);
        while (year_offset > 0 and n < cumulativeYearDays(@intCast(year_offset))) {
            year_offset -= 1;
        }
        year += year_offset;

        var day_of_year = n - cumulativeYearDays(@intCast(year_offset));
        const is_leap = cumulativeYearDays(@as(usize, @intCast(year_offset)) + 1) -
            cumulativeYearDays(@intCast(year_offset)) == 366;

        var month: i32 = undefined;
        if (is_leap) {
            month = leapMonthForDay(@intCast(day_of_year));
            day_of_year -= CUMULATIVE_LEAP_DAYS[@as(usize, @intCast(month)) - 1];
        } else {
            month = monthForDay(@intCast(day_of_year));
            day_of_year -= CUMULATIVE_DAYS[@as(usize, @intCast(month)) - 1];
        }

        return .{
            .year = year,
            .month = month,
            .day = day_of_year + 1,
        };
    }

    /// Create a date_t from year, month, day.
    pub fn fromDate(year_in: i32, month: i32, day: i32) !date_t {
        if (!isValid(year_in, month, day)) return error.InvalidDate;

        var year = year_in;
        var n: i32 = 0;

        while (year < 1970) {
            year += YEAR_INTERVAL;
            n -= DAYS_PER_YEAR_INTERVAL;
        }
        while (year >= 2370) {
            year -= YEAR_INTERVAL;
            n += DAYS_PER_YEAR_INTERVAL;
        }

        n += cumulativeYearDays(@intCast(year - 1970));
        n += if (isLeapYear(year))
            CUMULATIVE_LEAP_DAYS[@as(usize, @intCast(month)) - 1]
        else
            CUMULATIVE_DAYS[@as(usize, @intCast(month)) - 1];
        n += day - 1;

        return date_t.init(n);
    }

    /// Parse a date string in "YYYY-MM-DD" format.
    pub fn fromString(str: []const u8) !date_t {
        if (str.len < 8) return error.InvalidDate;

        var pos: usize = 0;
        // Skip leading spaces
        while (pos < str.len and str[pos] == ' ') pos += 1;

        // Parse year (variable length)
        var year: i32 = 0;
        while (pos < str.len and str[pos] >= '0' and str[pos] <= '9') {
            year = year * 10 + @as(i32, str[pos] - '0');
            pos += 1;
        }
        if (pos >= str.len) return error.InvalidDate;

        // Separator
        const sep = str[pos];
        if (sep != '-' and sep != '/' and sep != '\\' and sep != ' ') return error.InvalidDate;
        pos += 1;

        // Parse month
        const month = try parseDigits(str, &pos);
        if (pos >= str.len or str[pos] != sep) return error.InvalidDate;
        pos += 1;

        // Parse day
        const day = try parseDigits(str, &pos);

        return fromDate(year, month, day);
    }

    /// Format a date as "YYYY-MM-DD" string.
    pub fn toString(date: date_t, buf: []u8) []const u8 {
        const parts = convert(date);
        var pos: usize = 0;

        // Year (4 digits, zero-padded)
        const year_abs: u32 = if (parts.year >= 0)
            @intCast(parts.year)
        else
            @intCast(-parts.year);
        pos += writeUint(buf[pos..], year_abs, 4);

        buf[pos] = '-';
        pos += 1;
        pos += writeUint(buf[pos..], @intCast(parts.month), 2);
        buf[pos] = '-';
        pos += 1;
        pos += writeUint(buf[pos..], @intCast(parts.day), 2);

        return buf[0..pos];
    }

    /// Day of week: 0=Sunday, 1=Monday, ..., 6=Saturday.
    pub fn dayOfWeek(date: date_t) u32 {
        const d = date.days;
        if (d < 0) {
            return @intCast(@mod(7 - @mod(-d + 3, 7), 7));
        }
        return @intCast(@mod(@as(u32, @intCast(d)) + 3, 7) + 1);
    }

    // ========================================================================
    // Internal helpers
    // ========================================================================

    pub const DateParts = struct {
        year: i32,
        month: i32,
        day: i32,
    };

    fn parseDigits(str: []const u8, pos: *usize) !i32 {
        if (pos.* >= str.len or str[pos.*] < '0' or str[pos.*] > '9') return error.InvalidDate;
        var result: i32 = str[pos.*] - '0';
        pos.* += 1;
        if (pos.* < str.len and str[pos.*] >= '0' and str[pos.*] <= '9') {
            result = result * 10 + @as(i32, str[pos.*] - '0');
            pos.* += 1;
        }
        return result;
    }

    fn writeUint(buf: []u8, val: u32, width: u32) usize {
        var v = val;
        const w: usize = @intCast(width);
        var i: usize = w;
        while (i > 0) {
            i -= 1;
            buf[i] = @intCast('0' + @as(u8, @intCast(v % 10)));
            v /= 10;
        }
        return w;
    }

    // Cumulative year days lookup (precomputed for 400-year cycle)
    fn cumulativeYearDays(offset: usize) i32 {
        // Compute on the fly instead of storing 401-entry table
        var days: i32 = 0;
        for (0..offset) |i| {
            const y: i32 = EPOCH_YEAR + @as(i32, @intCast(i));
            days += if (isLeapYear(y)) 366 else 365;
        }
        return days;
    }

    fn monthForDay(day_of_year: usize) i32 {
        // Binary search through cumulative days
        var month: i32 = 1;
        while (month < 12) : (month += 1) {
            if (day_of_year < @as(usize, @intCast(CUMULATIVE_DAYS[@intCast(month)]))) break;
        }
        return month;
    }

    fn leapMonthForDay(day_of_year: usize) i32 {
        var month: i32 = 1;
        while (month < 12) : (month += 1) {
            if (day_of_year < @as(usize, @intCast(CUMULATIVE_LEAP_DAYS[@intCast(month)]))) break;
        }
        return month;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "date_t basic operations" {
    const d1 = date_t.init(0); // 1970-01-01
    const d2 = date_t.init(365); // 1971-01-01
    try std.testing.expect(d1.lessThan(d2));
    try std.testing.expect(d2.greaterThan(d1));
    try std.testing.expect(d1.eql(d1));
    try std.testing.expect(d1.addDays(365).eql(d2));
    try std.testing.expectEqual(@as(i64, -365), d1.diffDays(d2));
}

test "Date.isLeapYear" {
    try std.testing.expect(Date.isLeapYear(2000));
    try std.testing.expect(Date.isLeapYear(2024));
    try std.testing.expect(!Date.isLeapYear(1900));
    try std.testing.expect(!Date.isLeapYear(2023));
    try std.testing.expect(Date.isLeapYear(2400));
}

test "Date.isValid" {
    try std.testing.expect(Date.isValid(2024, 2, 29));
    try std.testing.expect(!Date.isValid(2023, 2, 29));
    try std.testing.expect(Date.isValid(2024, 1, 31));
    try std.testing.expect(!Date.isValid(2024, 4, 31));
    try std.testing.expect(!Date.isValid(2024, 13, 1));
    try std.testing.expect(!Date.isValid(2024, 0, 1));
}

test "Date.fromDate and convert roundtrip" {
    // 1970-01-01 = day 0
    const d1 = try Date.fromDate(1970, 1, 1);
    try std.testing.expectEqual(@as(i32, 0), d1.days);

    const p1 = Date.convert(d1);
    try std.testing.expectEqual(@as(i32, 1970), p1.year);
    try std.testing.expectEqual(@as(i32, 1), p1.month);
    try std.testing.expectEqual(@as(i32, 1), p1.day);

    // 2024-02-29 (leap day)
    const d2 = try Date.fromDate(2024, 2, 29);
    const p2 = Date.convert(d2);
    try std.testing.expectEqual(@as(i32, 2024), p2.year);
    try std.testing.expectEqual(@as(i32, 2), p2.month);
    try std.testing.expectEqual(@as(i32, 29), p2.day);

    // Invalid date
    try std.testing.expectError(error.InvalidDate, Date.fromDate(2024, 2, 30));
}

test "Date.fromString" {
    const d = try Date.fromString("2024-03-15");
    const parts = Date.convert(d);
    try std.testing.expectEqual(@as(i32, 2024), parts.year);
    try std.testing.expectEqual(@as(i32, 3), parts.month);
    try std.testing.expectEqual(@as(i32, 15), parts.day);

    // Slash separator
    const d2 = try Date.fromString("2000/01/01");
    const p2 = Date.convert(d2);
    try std.testing.expectEqual(@as(i32, 2000), p2.year);
}

test "Date.toString" {
    const d = try Date.fromDate(2024, 3, 15);
    var buf: [32]u8 = undefined;
    const str = Date.toString(d, &buf);
    try std.testing.expectEqualStrings("2024-03-15", str);
}

test "Date.monthDays" {
    try std.testing.expectEqual(@as(i32, 31), Date.monthDays(2024, 1));
    try std.testing.expectEqual(@as(i32, 29), Date.monthDays(2024, 2));
    try std.testing.expectEqual(@as(i32, 28), Date.monthDays(2023, 2));
    try std.testing.expectEqual(@as(i32, 30), Date.monthDays(2024, 4));
}

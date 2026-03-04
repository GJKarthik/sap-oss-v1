//! Date Time Types - Temporal data types
//!
//! Purpose:
//! Provides date, time, timestamp, and interval types
//! with arithmetic operations and formatting.

const std = @import("std");

// ============================================================================
// Date Type (days since epoch 1970-01-01)
// ============================================================================

pub const Date = struct {
    days: i32,  // Days since epoch
    
    pub const EPOCH_YEAR: i32 = 1970;
    pub const DAYS_PER_YEAR: i32 = 365;
    pub const DAYS_PER_LEAP_YEAR: i32 = 366;
    
    // Days in each month (non-leap year)
    const DAYS_IN_MONTH = [_]i32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const CUMULATIVE_DAYS = [_]i32{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
    
    pub fn init(days: i32) Date {
        return .{ .days = days };
    }
    
    pub fn fromYMD(year: i32, month: u32, day: u32) Date {
        var total_days: i32 = 0;
        
        // Days from years
        var y = EPOCH_YEAR;
        while (y < year) : (y += 1) {
            total_days += if (isLeapYear(y)) DAYS_PER_LEAP_YEAR else DAYS_PER_YEAR;
        }
        while (y > year) {
            y -= 1;
            total_days -= if (isLeapYear(y)) DAYS_PER_LEAP_YEAR else DAYS_PER_YEAR;
        }
        
        // Days from months
        if (month > 1) {
            total_days += CUMULATIVE_DAYS[month - 1];
            if (month > 2 and isLeapYear(year)) {
                total_days += 1;
            }
        }
        
        // Days
        total_days += @as(i32, @intCast(day)) - 1;
        
        return .{ .days = total_days };
    }
    
    pub fn toYMD(self: Date) struct { year: i32, month: u32, day: u32 } {
        var remaining = self.days;
        var year: i32 = EPOCH_YEAR;
        
        // Find year
        while (remaining >= (if (isLeapYear(year)) DAYS_PER_LEAP_YEAR else DAYS_PER_YEAR)) {
            remaining -= if (isLeapYear(year)) DAYS_PER_LEAP_YEAR else DAYS_PER_YEAR;
            year += 1;
        }
        while (remaining < 0) {
            year -= 1;
            remaining += if (isLeapYear(year)) DAYS_PER_LEAP_YEAR else DAYS_PER_YEAR;
        }
        
        // Find month
        const leap = isLeapYear(year);
        var month: u32 = 1;
        while (month < 12) {
            var days_in_month = DAYS_IN_MONTH[month - 1];
            if (month == 2 and leap) days_in_month += 1;
            
            if (remaining < days_in_month) break;
            remaining -= days_in_month;
            month += 1;
        }
        
        return .{
            .year = year,
            .month = month,
            .day = @intCast(remaining + 1),
        };
    }
    
    pub fn addDays(self: Date, days: i32) Date {
        return .{ .days = self.days + days };
    }
    
    pub fn addMonths(self: Date, months: i32) Date {
        const ymd = self.toYMD();
        var new_month = @as(i32, @intCast(ymd.month)) + months;
        var new_year = ymd.year;
        
        while (new_month > 12) {
            new_month -= 12;
            new_year += 1;
        }
        while (new_month < 1) {
            new_month += 12;
            new_year -= 1;
        }
        
        const max_day = daysInMonth(@intCast(new_month), new_year);
        const new_day = @min(ymd.day, max_day);
        
        return fromYMD(new_year, @intCast(new_month), new_day);
    }
    
    pub fn daysBetween(self: Date, other: Date) i32 {
        return other.days - self.days;
    }
    
    pub fn dayOfWeek(self: Date) u32 {
        // 1970-01-01 was Thursday (4)
        const dow = @mod(self.days + 4, 7);
        return if (dow < 0) @intCast(dow + 7) else @intCast(dow);
    }
    
    pub fn isLeapYear(year: i32) bool {
        return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
    }
    
    fn daysInMonth(month: u32, year: i32) u32 {
        if (month == 2 and isLeapYear(year)) return 29;
        return @intCast(DAYS_IN_MONTH[month - 1]);
    }
    
    pub fn format(self: Date, buf: []u8) ![]const u8 {
        const ymd = self.toYMD();
        return try std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ ymd.year, ymd.month, ymd.day });
    }
};

// ============================================================================
// Time Type (microseconds since midnight)
// ============================================================================

pub const Time = struct {
    micros: i64,  // Microseconds since midnight
    
    pub const MICROS_PER_SECOND: i64 = 1_000_000;
    pub const MICROS_PER_MINUTE: i64 = 60 * MICROS_PER_SECOND;
    pub const MICROS_PER_HOUR: i64 = 60 * MICROS_PER_MINUTE;
    pub const MICROS_PER_DAY: i64 = 24 * MICROS_PER_HOUR;
    
    pub fn init(micros: i64) Time {
        return .{ .micros = @mod(micros, MICROS_PER_DAY) };
    }
    
    pub fn fromHMS(hour: u32, minute: u32, second: u32) Time {
        return fromHMSMicros(hour, minute, second, 0);
    }
    
    pub fn fromHMSMicros(hour: u32, minute: u32, second: u32, micros: u32) Time {
        const total = @as(i64, hour) * MICROS_PER_HOUR +
            @as(i64, minute) * MICROS_PER_MINUTE +
            @as(i64, second) * MICROS_PER_SECOND +
            @as(i64, micros);
        return .{ .micros = total };
    }
    
    pub fn toHMS(self: Time) struct { hour: u32, minute: u32, second: u32, micros: u32 } {
        var remaining = self.micros;
        
        const hour: u32 = @intCast(@divFloor(remaining, MICROS_PER_HOUR));
        remaining = @mod(remaining, MICROS_PER_HOUR);
        
        const minute: u32 = @intCast(@divFloor(remaining, MICROS_PER_MINUTE));
        remaining = @mod(remaining, MICROS_PER_MINUTE);
        
        const second: u32 = @intCast(@divFloor(remaining, MICROS_PER_SECOND));
        const micros: u32 = @intCast(@mod(remaining, MICROS_PER_SECOND));
        
        return .{ .hour = hour, .minute = minute, .second = second, .micros = micros };
    }
    
    pub fn addMicroseconds(self: Time, micros: i64) Time {
        return Time.init(self.micros + micros);
    }
    
    pub fn addSeconds(self: Time, seconds: i64) Time {
        return Time.init(self.micros + seconds * MICROS_PER_SECOND);
    }
    
    pub fn format(self: Time, buf: []u8) ![]const u8 {
        const hms = self.toHMS();
        if (hms.micros > 0) {
            return try std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{ hms.hour, hms.minute, hms.second, hms.micros });
        }
        return try std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hms.hour, hms.minute, hms.second });
    }
};

// ============================================================================
// Timestamp Type (microseconds since epoch)
// ============================================================================

pub const Timestamp = struct {
    micros: i64,  // Microseconds since Unix epoch
    
    pub fn init(micros: i64) Timestamp {
        return .{ .micros = micros };
    }
    
    pub fn now() Timestamp {
        return .{ .micros = std.time.microTimestamp() };
    }
    
    pub fn fromDateAndTime(date: Date, time: Time) Timestamp {
        const date_micros = @as(i64, date.days) * Time.MICROS_PER_DAY;
        return .{ .micros = date_micros + time.micros };
    }
    
    pub fn toDate(self: Timestamp) Date {
        const days: i32 = @intCast(@divFloor(self.micros, Time.MICROS_PER_DAY));
        return Date.init(days);
    }
    
    pub fn toTime(self: Timestamp) Time {
        return Time.init(@mod(self.micros, Time.MICROS_PER_DAY));
    }
    
    pub fn addInterval(self: Timestamp, interval: Interval) Timestamp {
        var result = self.micros;
        
        // Add months
        if (interval.months != 0) {
            const date = self.toDate().addMonths(interval.months);
            const time = self.toTime();
            return Timestamp.fromDateAndTime(date, time).addInterval(Interval.init(0, interval.days, interval.micros));
        }
        
        // Add days
        result += @as(i64, interval.days) * Time.MICROS_PER_DAY;
        
        // Add microseconds
        result += interval.micros;
        
        return .{ .micros = result };
    }
    
    pub fn subtract(self: Timestamp, other: Timestamp) Interval {
        const diff = self.micros - other.micros;
        const days: i32 = @intCast(@divFloor(diff, Time.MICROS_PER_DAY));
        const remaining = @mod(diff, Time.MICROS_PER_DAY);
        return Interval.init(0, days, remaining);
    }
    
    pub fn format(self: Timestamp, buf: []u8) ![]const u8 {
        const date = self.toDate();
        const time = self.toTime();
        const ymd = date.toYMD();
        const hms = time.toHMS();
        
        return try std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            ymd.year, ymd.month, ymd.day, hms.hour, hms.minute, hms.second,
        });
    }
};

// ============================================================================
// Interval Type
// ============================================================================

pub const Interval = struct {
    months: i32,
    days: i32,
    micros: i64,
    
    pub fn init(months: i32, days: i32, micros: i64) Interval {
        return .{ .months = months, .days = days, .micros = micros };
    }
    
    pub fn fromYears(years: i32) Interval {
        return .{ .months = years * 12, .days = 0, .micros = 0 };
    }
    
    pub fn fromMonths(months: i32) Interval {
        return .{ .months = months, .days = 0, .micros = 0 };
    }
    
    pub fn fromDays(days: i32) Interval {
        return .{ .months = 0, .days = days, .micros = 0 };
    }
    
    pub fn fromHours(hours: i64) Interval {
        return .{ .months = 0, .days = 0, .micros = hours * Time.MICROS_PER_HOUR };
    }
    
    pub fn fromMinutes(minutes: i64) Interval {
        return .{ .months = 0, .days = 0, .micros = minutes * Time.MICROS_PER_MINUTE };
    }
    
    pub fn fromSeconds(seconds: i64) Interval {
        return .{ .months = 0, .days = 0, .micros = seconds * Time.MICROS_PER_SECOND };
    }
    
    pub fn add(self: Interval, other: Interval) Interval {
        return .{
            .months = self.months + other.months,
            .days = self.days + other.days,
            .micros = self.micros + other.micros,
        };
    }
    
    pub fn subtract(self: Interval, other: Interval) Interval {
        return .{
            .months = self.months - other.months,
            .days = self.days - other.days,
            .micros = self.micros - other.micros,
        };
    }
    
    pub fn multiply(self: Interval, factor: i32) Interval {
        return .{
            .months = self.months * factor,
            .days = self.days * factor,
            .micros = self.micros * factor,
        };
    }
    
    pub fn negate(self: Interval) Interval {
        return .{
            .months = -self.months,
            .days = -self.days,
            .micros = -self.micros,
        };
    }
    
    pub fn normalize(self: Interval) Interval {
        var result = self;
        
        // Normalize microseconds to days
        if (@abs(result.micros) >= Time.MICROS_PER_DAY) {
            const extra_days: i32 = @intCast(@divFloor(result.micros, Time.MICROS_PER_DAY));
            result.days += extra_days;
            result.micros = @mod(result.micros, Time.MICROS_PER_DAY);
        }
        
        return result;
    }
    
    pub fn format(self: Interval, buf: []u8) ![]const u8 {
        var pos: usize = 0;
        
        if (self.months != 0) {
            const years = @divFloor(self.months, 12);
            const months = @mod(self.months, 12);
            if (years != 0) {
                const written = try std.fmt.bufPrint(buf[pos..], "{d} years ", .{years});
                pos += written.len;
            }
            if (months != 0) {
                const written = try std.fmt.bufPrint(buf[pos..], "{d} months ", .{months});
                pos += written.len;
            }
        }
        
        if (self.days != 0) {
            const written = try std.fmt.bufPrint(buf[pos..], "{d} days ", .{self.days});
            pos += written.len;
        }
        
        if (self.micros != 0 or pos == 0) {
            const hours = @divFloor(self.micros, Time.MICROS_PER_HOUR);
            const remaining = @mod(self.micros, Time.MICROS_PER_HOUR);
            const minutes = @divFloor(remaining, Time.MICROS_PER_MINUTE);
            const seconds = @divFloor(@mod(remaining, Time.MICROS_PER_MINUTE), Time.MICROS_PER_SECOND);
            const written = try std.fmt.bufPrint(buf[pos..], "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds });
            pos += written.len;
        }
        
        return buf[0..pos];
    }
};

// ============================================================================
// Tests
// ============================================================================

test "date from ymd" {
    const date = Date.fromYMD(2024, 1, 15);
    const ymd = date.toYMD();
    
    try std.testing.expectEqual(@as(i32, 2024), ymd.year);
    try std.testing.expectEqual(@as(u32, 1), ymd.month);
    try std.testing.expectEqual(@as(u32, 15), ymd.day);
}

test "date epoch" {
    const date = Date.fromYMD(1970, 1, 1);
    try std.testing.expectEqual(@as(i32, 0), date.days);
}

test "date leap year" {
    try std.testing.expect(Date.isLeapYear(2000));
    try std.testing.expect(Date.isLeapYear(2024));
    try std.testing.expect(!Date.isLeapYear(1900));
    try std.testing.expect(!Date.isLeapYear(2023));
}

test "time from hms" {
    const time = Time.fromHMS(14, 30, 45);
    const hms = time.toHMS();
    
    try std.testing.expectEqual(@as(u32, 14), hms.hour);
    try std.testing.expectEqual(@as(u32, 30), hms.minute);
    try std.testing.expectEqual(@as(u32, 45), hms.second);
}

test "timestamp from date and time" {
    const date = Date.fromYMD(2024, 6, 15);
    const time = Time.fromHMS(12, 0, 0);
    const ts = Timestamp.fromDateAndTime(date, time);
    
    const result_date = ts.toDate().toYMD();
    try std.testing.expectEqual(@as(i32, 2024), result_date.year);
    try std.testing.expectEqual(@as(u32, 6), result_date.month);
}

test "interval arithmetic" {
    const i1 = Interval.fromDays(10);
    const i2 = Interval.fromDays(5);
    
    const sum = i1.add(i2);
    try std.testing.expectEqual(@as(i32, 15), sum.days);
    
    const diff = i1.subtract(i2);
    try std.testing.expectEqual(@as(i32, 5), diff.days);
}

test "interval from years" {
    const interval = Interval.fromYears(2);
    try std.testing.expectEqual(@as(i32, 24), interval.months);
}
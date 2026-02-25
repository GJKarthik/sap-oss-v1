//! Logging Framework for vLLM
//!
//! Provides structured logging with multiple levels, scoped loggers,
//! and optional file output.

const std = @import("std");
const builtin = @import("builtin");

/// Log levels in order of severity
pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
    fatal = 4,

    pub fn fromString(str: []const u8) Level {
        if (std.mem.eql(u8, str, "debug")) return .debug;
        if (std.mem.eql(u8, str, "info")) return .info;
        if (std.mem.eql(u8, str, "warn")) return .warn;
        if (std.mem.eql(u8, str, "err") or std.mem.eql(u8, str, "error")) return .err;
        if (std.mem.eql(u8, str, "fatal")) return .fatal;
        return .info; // default
    }

    pub fn toString(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
        };
    }

    pub fn color(self: Level) []const u8 {
        return switch (self) {
            .debug => "\x1b[36m", // cyan
            .info => "\x1b[32m", // green
            .warn => "\x1b[33m", // yellow
            .err => "\x1b[31m", // red
            .fatal => "\x1b[35m", // magenta
        };
    }
};

/// Global log level - messages below this level are suppressed
var global_level: Level = .info;

/// Whether to use colored output
var use_colors: bool = true;

/// Output writer
var output_writer: std.fs.File.Writer = std.io.getStdErr().writer();

/// Initialize the logging system
pub fn init(level: Level) void {
    global_level = level;
    use_colors = std.io.getStdErr().supportsAnsiEscapeCodes();
}

/// Set the global log level
pub fn setLevel(level: Level) void {
    global_level = level;
}

/// Get the current global log level
pub fn getLevel() Level {
    return global_level;
}

/// Enable or disable colored output
pub fn setColors(enabled: bool) void {
    use_colors = enabled;
}

/// Scoped logger with a specific component name
pub fn scoped(comptime scope: @Type(.EnumLiteral)) type {
    return struct {
        const scope_name = @tagName(scope);

        pub fn debug(comptime fmt: []const u8, args: anytype) void {
            log(.debug, scope_name, fmt, args);
        }

        pub fn info(comptime fmt: []const u8, args: anytype) void {
            log(.info, scope_name, fmt, args);
        }

        pub fn warn(comptime fmt: []const u8, args: anytype) void {
            log(.warn, scope_name, fmt, args);
        }

        pub fn err(comptime fmt: []const u8, args: anytype) void {
            log(.err, scope_name, fmt, args);
        }

        pub fn fatal(comptime fmt: []const u8, args: anytype) void {
            log(.fatal, scope_name, fmt, args);
        }
    };
}

/// Core logging function
pub fn log(level: Level, scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) < @intFromEnum(global_level)) {
        return;
    }

    const timestamp = getTimestamp();
    const reset = "\x1b[0m";

    // Format: [TIMESTAMP] [LEVEL] [scope] message
    if (use_colors) {
        output_writer.print("{s}[{s}] [{s}{s}{s}] [{s}] " ++ fmt ++ "{s}\n", .{
            "",
            timestamp,
            level.color(),
            level.toString(),
            reset,
            scope,
        } ++ args ++ .{reset}) catch {};
    } else {
        output_writer.print("[{s}] [{s}] [{s}] " ++ fmt ++ "\n", .{
            timestamp,
            level.toString(),
            scope,
        } ++ args) catch {};
    }
}

/// Get current timestamp as string
fn getTimestamp() []const u8 {
    // Use a static buffer for timestamp
    const S = struct {
        var buffer: [24]u8 = undefined;
    };

    const now = std.time.timestamp();
    const epoch_seconds: u64 = @intCast(now);

    // Simple formatting: HH:MM:SS
    const seconds_in_day = epoch_seconds % 86400;
    const hours = seconds_in_day / 3600;
    const minutes = (seconds_in_day % 3600) / 60;
    const seconds = seconds_in_day % 60;

    _ = std.fmt.bufPrint(&S.buffer, "{d:0>2}:{d:0>2}:{d:0>2}", .{
        hours,
        minutes,
        seconds,
    }) catch unreachable;

    return S.buffer[0..8];
}

/// Timer for performance measurement
pub const Timer = struct {
    start: i128,
    name: []const u8,

    const Self = @This();

    pub fn start(name: []const u8) Self {
        return Self{
            .start = std.time.nanoTimestamp(),
            .name = name,
        };
    }

    pub fn elapsed(self: *const Self) i64 {
        return @intCast(std.time.nanoTimestamp() - self.start);
    }

    pub fn elapsedMs(self: *const Self) f64 {
        return @as(f64, @floatFromInt(self.elapsed())) / 1_000_000.0;
    }

    pub fn stop(self: *const Self) void {
        const ms = self.elapsedMs();
        log(.debug, "timer", "{s} took {d:.3}ms", .{ self.name, ms });
    }
};

// ============================================
// Tests
// ============================================

test "Level fromString" {
    try std.testing.expectEqual(Level.debug, Level.fromString("debug"));
    try std.testing.expectEqual(Level.info, Level.fromString("info"));
    try std.testing.expectEqual(Level.warn, Level.fromString("warn"));
    try std.testing.expectEqual(Level.err, Level.fromString("err"));
    try std.testing.expectEqual(Level.err, Level.fromString("error"));
    try std.testing.expectEqual(Level.info, Level.fromString("unknown"));
}

test "Level toString" {
    try std.testing.expectEqualStrings("DEBUG", Level.debug.toString());
    try std.testing.expectEqualStrings("INFO", Level.info.toString());
    try std.testing.expectEqualStrings("ERROR", Level.err.toString());
}

test "setLevel and getLevel" {
    const original = getLevel();
    defer setLevel(original);

    setLevel(.debug);
    try std.testing.expectEqual(Level.debug, getLevel());

    setLevel(.err);
    try std.testing.expectEqual(Level.err, getLevel());
}

test "Timer measurement" {
    var timer = Timer.start("test");
    std.time.sleep(1_000_000); // 1ms
    const elapsed = timer.elapsedMs();
    try std.testing.expect(elapsed >= 0.5);
}
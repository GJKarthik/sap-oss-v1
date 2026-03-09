//! Logger - Structured logging system
//!
//! Purpose:
//! Provides hierarchical logging with levels, timestamps,
//! and structured key-value data for debugging and monitoring.

const std = @import("std");

// ============================================================================
// Log Level
// ============================================================================

pub const LogLevel = enum(u8) {
    TRACE = 0,
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4,
    FATAL = 5,
    OFF = 255,
    
    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .TRACE => "TRACE",
            .DEBUG => "DEBUG",
            .INFO => "INFO",
            .WARN => "WARN",
            .ERROR => "ERROR",
            .FATAL => "FATAL",
            .OFF => "OFF",
        };
    }
    
    pub fn toShort(self: LogLevel) []const u8 {
        return switch (self) {
            .TRACE => "T",
            .DEBUG => "D",
            .INFO => "I",
            .WARN => "W",
            .ERROR => "E",
            .FATAL => "F",
            .OFF => "-",
        };
    }
};

// ============================================================================
// Log Entry
// ============================================================================

pub const LogEntry = struct {
    level: LogLevel,
    timestamp: i64,
    message: []const u8,
    category: []const u8 = "",
    file: []const u8 = "",
    line: u32 = 0,
    
    pub fn init(level: LogLevel, message: []const u8) LogEntry {
        return .{
            .level = level,
            .timestamp = std.time.timestamp(),
            .message = message,
        };
    }
};

// ============================================================================
// Log Sink (Output destination)
// ============================================================================

pub const LogSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    
    pub const VTable = struct {
        write: *const fn (ptr: *anyopaque, entry: LogEntry) void,
        flush: *const fn (ptr: *anyopaque) void,
    };
    
    pub fn write(self: LogSink, entry: LogEntry) void {
        self.vtable.write(self.ptr, entry);
    }
    
    pub fn flush(self: LogSink) void {
        self.vtable.flush(self.ptr);
    }
};

// ============================================================================
// Console Sink
// ============================================================================

pub const ConsoleSink = struct {
    use_colors: bool = true,
    
    const vtable = LogSink.VTable{
        .write = write,
        .flush = flush,
    };
    
    pub fn toSink(self: *ConsoleSink) LogSink {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
    
    fn write(ptr: *anyopaque, entry: LogEntry) void {
        const self: *ConsoleSink = @ptrCast(@alignCast(ptr));
        const writer = std.io.getStdErr().writer();
        
        // Format timestamp
        const ts = entry.timestamp;
        const secs = @mod(ts, 86400);
        const hours: u32 = @intCast(@divFloor(secs, 3600));
        const mins: u32 = @intCast(@mod(@divFloor(secs, 60), 60));
        const s: u32 = @intCast(@mod(secs, 60));
        
        if (self.use_colors) {
            const color = switch (entry.level) {
                .TRACE => "\x1b[90m",
                .DEBUG => "\x1b[36m",
                .INFO => "\x1b[32m",
                .WARN => "\x1b[33m",
                .ERROR => "\x1b[31m",
                .FATAL => "\x1b[35m",
                .OFF => "",
            };
            writer.print("{s}{d:0>2}:{d:0>2}:{d:0>2} [{s}] {s}\x1b[0m\n", .{
                color, hours, mins, s, entry.level.toString(), entry.message,
            }) catch {};
        } else {
            writer.print("{d:0>2}:{d:0>2}:{d:0>2} [{s}] {s}\n", .{
                hours, mins, s, entry.level.toString(), entry.message,
            }) catch {};
        }
    }
    
    fn flush(_: *anyopaque) void {
        // stderr is unbuffered
    }
};

// ============================================================================
// Buffer Sink (stores entries in memory)
// ============================================================================

pub const BufferSink = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(LogEntry),
    max_entries: usize = 1000,
    
    const vtable = LogSink.VTable{
        .write = _write,
        .flush = flush,
    };
    
    pub fn init(allocator: std.mem.Allocator) BufferSink {
        return .{
            .allocator = allocator,
            .entries = .{},
        };
    }
    
    pub fn deinit(self: *BufferSink) void {
        self.entries.deinit(self.allocator);
    }
    
    pub fn toSink(self: *BufferSink) LogSink {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
    
    fn _write(ptr: *anyopaque, entry: LogEntry) void {
        const self: *BufferSink = @ptrCast(@alignCast(ptr));
        
        // Remove oldest if at capacity
        if (self.entries.items.len >= self.max_entries) {
            _ = self.entries.orderedRemove(0);
        }
        
        self.entries.append(self.allocator, entry) catch {};
    }
    
    fn flush(_: *anyopaque) void {}
    
    pub fn getEntries(self: *const BufferSink) []const LogEntry {
        return self.entries.items;
    }
    
    pub fn clear(self: *BufferSink) void {
        self.entries.clearRetainingCapacity();
    }


// ============================================================================
// Logger
// ============================================================================

pub const Logger = struct {
    allocator: std.mem.Allocator,
    level: LogLevel = .INFO,
    category: []const u8 = "",
    sinks: std.ArrayList(LogSink),
    enabled: bool = true,
    
    pub fn init(allocator: std.mem.Allocator) Logger {
        return .{
            .allocator = allocator,
            .sinks = .{},
        };
    }
    
    pub fn deinit(self: *Logger) void {
        self.sinks.deinit(self.allocator);
    }
    
    pub fn addSink(self: *Logger, sink: LogSink) !void {
        try self.sinks.append(self.allocator, sink);
    }
    
    pub fn setLevel(self: *Logger, level: LogLevel) void {
        self.level = level;
    }
    
    pub fn setCategory(self: *Logger, category: []const u8) void {
        self.category = category;
    }
    
    pub fn enable(self: *Logger) void {
        self.enabled = true;
    }
    
    pub fn disable(self: *Logger) void {
        self.enabled = false;
    }
    
    fn log(self: *Logger, level: LogLevel, message: []const u8) void {
        if (!self.enabled) return;
        if (@intFromEnum(level) < @intFromEnum(self.level)) return;
        
        var entry = LogEntry.init(level, message);
        entry.category = self.category;
        
        for (self.sinks.items) |sink| {
            sink.write(entry);
        }
    }
    
    pub fn trace(self: *Logger, message: []const u8) void {
        self.log(.TRACE, message);
    }
    
    pub fn debug(self: *Logger, message: []const u8) void {
        self.log(.DEBUG, message);
    }
    
    pub fn info(self: *Logger, message: []const u8) void {
        self.log(.INFO, message);
    }
    
    pub fn warn(self: *Logger, message: []const u8) void {
        self.log(.WARN, message);
    }
    
    pub fn err(self: *Logger, message: []const u8) void {
        self.log(.ERROR, message);
    }
    
    pub fn fatal(self: *Logger, message: []const u8) void {
        self.log(.FATAL, message);
    }
    
    pub fn flush(self: *Logger) void {
        for (self.sinks.items) |sink| {
            sink.flush();
        }
    }
};

// ============================================================================
// Global Logger
// ============================================================================

var global_logger: ?*Logger = null;

pub fn setGlobalLogger(logger: *Logger) void {
    global_logger = logger;
}

pub fn getGlobalLogger() ?*Logger {
    return global_logger;
}

// ============================================================================
// Tests
// ============================================================================

test "log level" {
    try std.testing.expectEqualStrings("INFO", LogLevel.INFO.toString());
    try std.testing.expectEqualStrings("E", LogLevel.ERROR.toShort());
}

test "log entry" {
    const entry = LogEntry.init(.INFO, "test message");
    try std.testing.expectEqual(LogLevel.INFO, entry.level);
    try std.testing.expectEqualStrings("test message", entry.message);
}

test "logger basic" {
    const allocator = std.testing.allocator;
    
    var buffer_sink = BufferSink.init(allocator);
    defer buffer_sink.deinit();
    
    var logger = Logger.init(allocator);
    defer logger.deinit();
    
    try logger.addSink(buffer_sink.toSink());
    
    logger.info("test info");
    logger.warn("test warning");
    logger.trace("should not appear");  // Below INFO level
    
    const entries = buffer_sink.getEntries();
    try std.testing.expectEqual(@as(usize, 2), entries.len);
}

test "logger level filter" {
    const allocator = std.testing.allocator;
    
    var buffer_sink = BufferSink.init(allocator);
    defer buffer_sink.deinit();
    
    var logger = Logger.init(allocator);
    defer logger.deinit();
    
    try logger.addSink(buffer_sink.toSink());
    logger.setLevel(.ERROR);
    
    logger.info("info");
    logger.warn("warn");
    logger.err("error");
    
    const entries = buffer_sink.getEntries();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
}

test "logger disable" {
    const allocator = std.testing.allocator;
    
    var buffer_sink = BufferSink.init(allocator);
    defer buffer_sink.deinit();
    
    var logger = Logger.init(allocator);
    defer logger.deinit();
    
    try logger.addSink(buffer_sink.toSink());
    logger.disable();
    
    logger.info("test");
    
    const entries = buffer_sink.getEntries();
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "buffer sink max entries" {
    const allocator = std.testing.allocator;
    
    var buffer_sink = BufferSink.init(allocator);
    defer buffer_sink.deinit();
    buffer_sink.max_entries = 3;
    
    var logger = Logger.init(allocator);
    defer logger.deinit();
    
    try logger.addSink(buffer_sink.toSink());
    
    logger.info("1");
    logger.info("2");
    logger.info("3");
    logger.info("4");
    
    const entries = buffer_sink.getEntries();
    try std.testing.expectEqual(@as(usize, 3), entries.len);
}
};

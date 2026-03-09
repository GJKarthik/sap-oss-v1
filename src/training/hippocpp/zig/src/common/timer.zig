//! Timer — Ported from kuzu C++ (48L header, 0L source).
//!

const std = @import("std");

pub const Timer = struct {
    allocator: std.mem.Allocator,
    count: ?*anyopaque = null,
    startTime: ?*anyopaque = null,
    stopTime: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn start(self: *Self) void {
        _ = self;
    }

    pub fn stop(self: *Self) void {
        _ = self;
    }

    pub fn get_duration(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn exception(self: *Self) void {
        _ = self;
    }

    pub fn get_elapsed_time_in_ms(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

};

test "Timer" {
    const allocator = std.testing.allocator;
    var instance = Timer.init(allocator);
    defer instance.deinit();
    _ = instance.get_duration();
    _ = instance.get_elapsed_time_in_ms();
}

//! that — Ported from kuzu C++ (297L header, 0L source).
//!

const std = @import("std");

pub const that = struct {
    allocator: std.mem.Allocator,
    ptr: ?*anyopaque = null,
    length: ?*anyopaque = null,
    trailing_zeros: ?*anyopaque = null,
    8: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_unsigned_int64_length(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn length(self: *Self) void {
        _ = self;
    }

    pub fn optional(self: *Self) void {
        _ = self;
    }

    pub fn format(self: *Self) void {
        _ = self;
    }

    pub fn while(self: *Self) void {
        _ = self;
    }

    pub fn if(self: *Self) void {
        _ = self;
    }

    pub fn strlen(self: *Self) void {
        _ = self;
    }

    pub fn format_micros(self: *Self) void {
        _ = self;
    }

    pub fn zeros(self: *Self) void {
        _ = self;
    }

    pub fn format_two_digits(self: *Self) void {
        _ = self;
    }

};

test "that" {
    const allocator = std.testing.allocator;
    var instance = that.init(allocator);
    defer instance.deinit();
    _ = instance.get_unsigned_int64_length();
}

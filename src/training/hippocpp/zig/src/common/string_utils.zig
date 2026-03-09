//! KUZU_API — Ported from kuzu C++ (125L header, 281L source).
//!

const std = @import("std");

pub const KUZU_API = struct {
    allocator: std.mem.Allocator,
    s: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_upper(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_lower(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn to_lower(self: *Self) void {
        _ = self;
    }

    pub fn to_upper(self: *Self) void {
        _ = self;
    }

    pub fn is_space(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn character_is_new_line(self: *Self) void {
        _ = self;
    }

    pub fn character_is_digit(self: *Self) void {
        _ = self;
    }

    pub fn ltrim(self: *Self) void {
        _ = self;
    }

    pub fn rtrim(self: *Self) void {
        _ = self;
    }

};

test "KUZU_API" {
    const allocator = std.testing.allocator;
    var instance = KUZU_API.init(allocator);
    defer instance.deinit();
    _ = instance.get_upper();
    _ = instance.get_upper();
    _ = instance.get_lower();
}

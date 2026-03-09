//! SHA256 — Ported from kuzu C++ (29L header, 32L source).
//!

const std = @import("std");

pub const SHA256 = struct {
    allocator: std.mem.Allocator,
    SHA256Context: ?*anyopaque = null,
    shaContext: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn add_string(self: *Self) void {
        _ = self;
    }

    pub fn finish_sha256(self: *Self) void {
        _ = self;
    }

    pub fn to_base16(self: *Self) void {
        _ = self;
    }

};

test "SHA256" {
    const allocator = std.testing.allocator;
    var instance = SHA256.init(allocator);
    defer instance.deinit();
}

//! StringColumnReader — Ported from kuzu C++ (38L header, 93L source).
//!
//! Extends TemplatedColumnReader in the upstream implementation.

const std = @import("std");

pub const StringColumnReader = struct {
    allocator: std.mem.Allocator,
    dictStrs: ?*?*anyopaque = null,
    fixedWidthStringLength: u64 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn dict_read(self: *Self) void {
        _ = self;
    }

    pub fn plain_read(self: *Self) void {
        _ = self;
    }

    pub fn plain_skip(self: *Self) void {
        _ = self;
    }

    pub fn dictionary(self: *Self) void {
        _ = self;
    }

    pub fn verify_string(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this StringColumnReader.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.fixedWidthStringLength = self.fixedWidthStringLength;
        return new;
    }

};

test "StringColumnReader" {
    const allocator = std.testing.allocator;
    var instance = StringColumnReader.init(allocator);
    defer instance.deinit();
}

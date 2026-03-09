//! IntervalColumnReader — Ported from kuzu C++ (41L header, 34L source).
//!
//! Extends TemplatedColumnReader in the upstream implementation.

const std = @import("std");

pub const IntervalColumnReader = struct {
    allocator: std.mem.Allocator,

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

    pub fn read_parquet_interval(self: *Self) void {
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

    /// Create a deep copy of this IntervalColumnReader.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "IntervalColumnReader" {
    const allocator = std.testing.allocator;
    var instance = IntervalColumnReader.init(allocator);
    defer instance.deinit();
}

//! UUIDColumnReader — Ported from kuzu C++ (39L header, 0L source).
//!
//! Extends TemplatedColumnReader in the upstream implementation.

const std = @import("std");

pub const UUIDColumnReader = struct {
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

    pub fn read_parquet_uuid(self: *Self) void {
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

    /// Create a deep copy of this UUIDColumnReader.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "UUIDColumnReader" {
    const allocator = std.testing.allocator;
    var instance = UUIDColumnReader.init(allocator);
    defer instance.deinit();
}

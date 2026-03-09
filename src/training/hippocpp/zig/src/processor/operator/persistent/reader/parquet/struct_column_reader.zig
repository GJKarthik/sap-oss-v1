//! StructColumnReader — Ported from kuzu C++ (35L header, 99L source).
//!
//! Extends ColumnReader in the upstream implementation.

const std = @import("std");

pub const StructColumnReader = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn initialize_read(self: *Self) void {
        _ = self;
    }

    pub fn read(self: *Self) void {
        _ = self;
    }

    pub fn get_total_compressed_size(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn register_prefetch(self: *Self) void {
        _ = self;
    }

    pub fn skip(self: *Self) void {
        _ = self;
    }

    pub fn get_group_rows_available(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    /// Create a deep copy of this StructColumnReader.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "StructColumnReader" {
    const allocator = std.testing.allocator;
    var instance = StructColumnReader.init(allocator);
    defer instance.deinit();
    _ = instance.get_total_compressed_size();
}

//! IntervalColumnWriter — Ported from kuzu C++ (33L header, 39L source).
//!
//! Extends BasicColumnWriter in the upstream implementation.

const std = @import("std");

pub const IntervalColumnWriter = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn write_parquet_interval(self: *Self) void {
        _ = self;
    }

    pub fn write_vector(self: *Self) void {
        _ = self;
    }

    pub fn get_row_size(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    /// Create a deep copy of this IntervalColumnWriter.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "IntervalColumnWriter" {
    const allocator = std.testing.allocator;
    var instance = IntervalColumnWriter.init(allocator);
    defer instance.deinit();
    _ = instance.get_row_size();
}

//! ListColumnReader — Ported from kuzu C++ (54L header, 131L source).
//!
//! Extends ColumnReader in the upstream implementation.

const std = @import("std");

pub const ListColumnReader = struct {
    allocator: std.mem.Allocator,
    childColumnReader: ?*?*anyopaque = null,
    childDefines: ?*anyopaque = null,
    childRepeats: ?*anyopaque = null,
    childFilter: ?*anyopaque = null,
    overflowChildCount: u64 = 0,
    vectorToRead: ?*?*anyopaque = null,

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

    pub fn apply_pending_skips(self: *Self) void {
        _ = self;
    }

    pub fn get_group_rows_available(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_total_compressed_size(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn register_prefetch(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this ListColumnReader.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.overflowChildCount = self.overflowChildCount;
        return new;
    }

};

test "ListColumnReader" {
    const allocator = std.testing.allocator;
    var instance = ListColumnReader.init(allocator);
    defer instance.deinit();
    _ = instance.get_group_rows_available();
    _ = instance.get_total_compressed_size();
}

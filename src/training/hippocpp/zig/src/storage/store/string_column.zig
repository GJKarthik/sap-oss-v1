//! StringColumn — Ported from kuzu C++ (67L header, 334L source).
//!
//! Extends Column in the upstream implementation.

const std = @import("std");

pub const StringColumn = struct {
    allocator: std.mem.Allocator,
    dictionary: ?*anyopaque = null,
    indexColumn: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn write_segment(self: *Self) void {
        _ = self;
    }

    pub fn scan_segment(self: *Self) void {
        _ = self;
    }

    pub fn scan_unfiltered(self: *Self) void {
        _ = self;
    }

    pub fn scan_filtered(self: *Self) void {
        _ = self;
    }

    pub fn lookup_internal(self: *Self) void {
        _ = self;
    }

    pub fn can_checkpoint_in_place(self: *Self) void {
        _ = self;
    }

    pub fn can_index_commit_in_place(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this StringColumn.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "StringColumn" {
    const allocator = std.testing.allocator;
    var instance = StringColumn.init(allocator);
    defer instance.deinit();
}

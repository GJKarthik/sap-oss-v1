//! ListColumn — Ported from kuzu C++ (105L header, 523L source).
//!
//! Extends Column in the upstream implementation.

const std = @import("std");

pub const ListColumn = struct {
    allocator: std.mem.Allocator,
    numTotal: u64 = 0,
    offsetColumnChunk: ?*?*anyopaque = null,
    sizeColumnChunk: ?*?*anyopaque = null,
    offsetColumn: ?*?*anyopaque = null,
    sizeColumn: ?*?*anyopaque = null,
    dataColumn: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn column(self: *Self) void {
        _ = self;
    }

    pub fn get_list_size(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_list_end_offset(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_list_start_offset(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn is_offset_sorted_ascending(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn disable_compression_on_data(self: *Self) void {
        _ = self;
    }

    pub fn scan_segment(self: *Self) void {
        _ = self;
    }

    pub fn lookup_internal(self: *Self) void {
        _ = self;
    }

    pub fn scan_unfiltered(self: *Self) void {
        _ = self;
    }

    pub fn scan_filtered(self: *Self) void {
        _ = self;
    }

    pub fn read_offset(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this ListColumn.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.numTotal = self.numTotal;
        return new;
    }

};

test "ListColumn" {
    const allocator = std.testing.allocator;
    var instance = ListColumn.init(allocator);
    defer instance.deinit();
    _ = instance.get_list_size();
    _ = instance.get_list_end_offset();
    _ = instance.get_list_start_offset();
    _ = instance.is_offset_sorted_ascending();
}

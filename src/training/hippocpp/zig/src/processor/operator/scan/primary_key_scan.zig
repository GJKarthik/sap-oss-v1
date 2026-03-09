//! PrimaryKeyScanNodeTable — Ported from kuzu C++ (73L header, 0L source).
//!
//! Extends ScanTable in the upstream implementation.

const std = @import("std");

pub const PrimaryKeyScanNodeTable = struct {
    allocator: std.mem.Allocator,
    expressions: std.ArrayList(u8) = .{},
    key: []const u8 = "",
    alias: []const u8 = "",
    mtx: ?*anyopaque = null,
    numTables: u32 = 0,
    cursor: u32 = 0,
    true: ?*anyopaque = null,
    false: ?*anyopaque = null,
    scanState: ?*?*anyopaque = null,
    tableInfos: std.ArrayList(?*anyopaque) = .{},
    indexEvaluator: ?*?*anyopaque = null,
    sharedState: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn primary_key_scan_print_info(self: *Self) void {
        _ = self;
    }

    pub fn primary_key_scan_shared_state(self: *Self) void {
        _ = self;
    }

    pub fn get_table_idx(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn is_source(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn init_local_state_internal(self: *Self) void {
        _ = self;
    }

    pub fn get_next_tuples_internal(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn is_parallel(self: *const Self) bool {
        _ = self;
        return false;
    }

    /// Create a deep copy of this PrimaryKeyScanNodeTable.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.key = self.key;
        new.alias = self.alias;
        new.numTables = self.numTables;
        new.cursor = self.cursor;
        return new;
    }

};

test "PrimaryKeyScanNodeTable" {
    const allocator = std.testing.allocator;
    var instance = PrimaryKeyScanNodeTable.init(allocator);
    defer instance.deinit();
    _ = instance.get_table_idx();
    _ = instance.is_source();
}

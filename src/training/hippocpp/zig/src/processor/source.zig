//! TARGET — Ported from kuzu C++ (85L header, 0L source).
//!

const std = @import("std");

pub const TARGET = struct {
    allocator: std.mem.Allocator,
    type: ?*anyopaque = null,
    0: ?*anyopaque = null,
    info: ?*anyopaque = null,
    statement: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn bound_base_scan_source(self: *Self) void {
        _ = self;
    }

    pub fn get_columns(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_warning_columns(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_ignore_errors_option(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_num_warning_data_columns(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn bound_table_scan_source(self: *Self) void {
        _ = self;
    }

    pub fn bound_query_scan_source(self: *Self) void {
        _ = self;
    }

};

test "TARGET" {
    const allocator = std.testing.allocator;
    var instance = TARGET.init(allocator);
    defer instance.deinit();
    _ = instance.get_columns();
    _ = instance.get_warning_columns();
    _ = instance.get_ignore_errors_option();
    _ = instance.get_num_warning_data_columns();
}

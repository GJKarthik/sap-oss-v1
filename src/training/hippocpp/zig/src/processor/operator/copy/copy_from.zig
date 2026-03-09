//! TARGET — Ported from kuzu C++ (101L header, 0L source).
//!

const std = @import("std");

pub const TARGET = struct {
    allocator: std.mem.Allocator,
    tableName: []const u8 = "",
    tableType: ?*anyopaque = null,
    source: ?*?*anyopaque = null,
    offset: ?*?*anyopaque = null,
    columnExprs: std.ArrayList(u8) = .{},
    columnEvaluateTypes: std.ArrayList(?*anyopaque) = .{},
    extraInfo: ?*?*anyopaque = null,
    fromTableName: []const u8 = "",
    toTableName: []const u8 = "",
    internalIDColumnIndices: std.ArrayList(?*anyopaque) = .{},
    infos: std.ArrayList(?*anyopaque) = .{},
    info: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_source_columns(self: *const Self) ?*anyopaque {
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

    pub fn offset(self: *Self) void {
        _ = self;
    }

    pub fn bound_copy_from(self: *Self) void {
        _ = self;
    }

};

test "TARGET" {
    const allocator = std.testing.allocator;
    var instance = TARGET.init(allocator);
    defer instance.deinit();
    _ = instance.get_source_columns();
    _ = instance.get_warning_columns();
    _ = instance.get_ignore_errors_option();
}

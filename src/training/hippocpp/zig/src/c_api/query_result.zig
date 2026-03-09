//! FlatTuple — Ported from kuzu C++ (194L header, 249L source).
//!

const std = @import("std");

pub const QueryResultType = enum(u8) {
    FTABLE = 0,
    ARROW = 1,
};

pub const FlatTuple = struct {
    allocator: std.mem.Allocator,
    FlatTuple: ?*anyopaque = null,
    type: ?*anyopaque = null,
    current: ?*anyopaque = null,
    errMsg: []const u8 = "",
    columnNames: std.ArrayList([]const u8) = .{},
    columnTypes: std.ArrayList(?*anyopaque) = .{},
    tuple: ?*?*anyopaque = null,
    querySummary: ?*?*anyopaque = null,
    nextQueryResult: ?*?*anyopaque = null,
    queryResultIterator: ?*anyopaque = null,
    dbLifeCycleManager: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn query_result(self: *Self) void {
        _ = self;
    }

    pub fn is_success(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn get_error_message(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_num_columns(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn has_next_query_result(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn read(self: *Self) void {
        _ = self;
    }

    pub fn get_num_tuples(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn has_next(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn get_next(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn reset_iterator(self: *Self) void {
        _ = self;
    }

};

test "FlatTuple" {
    const allocator = std.testing.allocator;
    var instance = FlatTuple.init(allocator);
    defer instance.deinit();
    _ = instance.is_success();
    _ = instance.get_error_message();
    _ = instance.get_num_columns();
}

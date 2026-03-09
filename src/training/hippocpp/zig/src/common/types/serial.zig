//! that — Ported from kuzu C++ (67L header, 0L source).
//!

const std = @import("std");

pub const that = struct {
    allocator: std.mem.Allocator,
    true: ?*anyopaque = null,
    reader: ?*?*anyopaque = null,
    csvOption: ?*anyopaque = null,
    columnInfo: ?*anyopaque = null,
    totalReadSizeByFile: u64 = 0,
    sharedErrorHandler: ?*?*anyopaque = null,
    localErrorHandler: ?*?*anyopaque = null,
    queryID: u64 = 0,
    populateErrorFunc: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn parse_block(self: *Self) void {
        _ = self;
    }

    pub fn handle_quoted_newline(self: *Self) void {
        _ = self;
    }

    pub fn reset_reader_state(self: *Self) void {
        _ = self;
    }

    pub fn detect_dialect(self: *Self) void {
        _ = self;
    }

    pub fn detect_header(self: *Self) void {
        _ = self;
    }

    pub fn read(self: *Self) void {
        _ = self;
    }

    pub fn init_reader(self: *Self) void {
        _ = self;
    }

    pub fn finalize_reader(self: *Self) void {
        _ = self;
    }

    pub fn construct_populate_func(self: *Self) void {
        _ = self;
    }

    pub fn get_function_set(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn bind_columns(self: *Self) void {
        _ = self;
    }

};

test "that" {
    const allocator = std.testing.allocator;
    var instance = that.init(allocator);
    defer instance.deinit();
}

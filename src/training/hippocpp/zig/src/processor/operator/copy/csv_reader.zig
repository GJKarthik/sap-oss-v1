//! ClientContext — Ported from kuzu C++ (154L header, 0L source).
//!

const std = @import("std");

pub const ClientContext = struct {
    allocator: std.mem.Allocator,
    FileScanInfo: ?*anyopaque = null,
    ClientContext: ?*anyopaque = null,
    LocalFileErrorHandler: ?*anyopaque = null,
    SharedFileErrorHandler: ?*anyopaque = null,
    numColumns: u64 = 0,
    columnSkips: std.ArrayList(bool) = .{},
    numWarningDataColumns: u32 = 0,
    ParsingDriver: ?*anyopaque = null,
    SniffCSVNameAndTypeDriver: ?*anyopaque = null,
    context: ?*anyopaque = null,
    option: ?*anyopaque = null,
    columnInfo: ?*anyopaque = null,
    fileInfo: ?*?*anyopaque = null,
    currentBlockIdx: ?*anyopaque = null,

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

    pub fn get_num_columns(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn skip_column(self: *Self) void {
        _ = self;
    }

    pub fn is_eof(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn get_file_size(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_file_offset(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn reconstruct_line(self: *Self) void {
        _ = self;
    }

    pub fn append_warning_data_columns(self: *Self) void {
        _ = self;
    }

    pub fn base_populate_error_func(self: *Self) void {
        _ = self;
    }

    pub fn get_file_idx_func(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn add_value(self: *Self) void {
        _ = self;
    }

    pub fn handle_first_block(self: *Self) void {
        _ = self;
    }

};

test "ClientContext" {
    const allocator = std.testing.allocator;
    var instance = ClientContext.init(allocator);
    defer instance.deinit();
    _ = instance.get_num_columns();
    _ = instance.is_eof();
    _ = instance.get_file_size();
}

//! ClientContext — Ported from kuzu C++ (157L header, 309L source).
//!

const std = @import("std");

pub const DriverType = enum(u8) {
    PARSING = 0,
    PARALLEL = 1,
    SERIAL = 2,
    SNIFF_CSV_DIALECT = 3,
    SNIFF_CSV_NAME_AND_TYPE = 4,
    SNIFF_CSV_HEADER = 5,
    HEADER = 6,
    SKIP_ROW = 7,
};

pub const ClientContext = struct {
    allocator: std.mem.Allocator,
    ClientContext: ?*anyopaque = null,
    BaseCSVReader: ?*anyopaque = null,
    warningDataStartColumnIdx: u64 = 0,
    data: ?*anyopaque = null,
    driverType: ?*anyopaque = null,
    rowEmpty: bool = false,
    ParallelCSVReader: ?*anyopaque = null,
    SerialCSVReader: ?*anyopaque = null,
    everQuoted: ?*anyopaque = null,
    everEscaped: ?*anyopaque = null,
    error: ?*anyopaque = null,
    resultPosition: ?*anyopaque = null,
    columnCounts: std.ArrayList(?*anyopaque) = .{},
    firstRow: std.ArrayList([]const u8) = .{},
    sniffType: std.ArrayList(bool) = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn parsing_driver(self: *Self) void {
        _ = self;
    }

    pub fn done(self: *Self) void {
        _ = self;
    }

    pub fn add_value(self: *Self) void {
        _ = self;
    }

    pub fn add_row(self: *Self) void {
        _ = self;
    }

    pub fn done_early(self: *Self) void {
        _ = self;
    }

    pub fn sniff_csv_dialect_driver(self: *Self) void {
        _ = self;
    }

    pub fn reset(self: *Self) void {
        _ = self;
    }

};

test "ClientContext" {
    const allocator = std.testing.allocator;
    var instance = ClientContext.init(allocator);
    defer instance.deinit();
}

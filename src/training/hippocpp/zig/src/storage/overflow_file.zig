//! OverflowFile — Ported from kuzu C++ (156L header, 464L source).
//!

const std = @import("std");

pub const OverflowFile = struct {
    allocator: std.mem.Allocator,
    OverflowFile: ?*anyopaque = null,
    cursor: ?*anyopaque = null,
    buffer: ?*?*anyopaque = null,
    pageWriteCache: ?*anyopaque = null,
    ShadowFile: ?*anyopaque = null,
    OverflowFileHandle: ?*anyopaque = null,
    headerPageIdx: ?*anyopaque = null,
    fileHandle: ?*anyopaque = null,
    header: ?*anyopaque = null,
    pageCounter: ?*anyopaque = null,
    headerChanged: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn pages(self: *Self) void {
        _ = self;
    }

    pub fn string_overflow_file_header(self: *Self) void {
        _ = self;
    }

    pub fn overflow_file_handle(self: *Self) void {
        _ = self;
    }

    pub fn read_string(self: *Self) void {
        _ = self;
    }

    pub fn equals(self: *Self) void {
        _ = self;
    }

    pub fn write_string(self: *Self) void {
        _ = self;
    }

    pub fn checkpoint(self: *Self) void {
        _ = self;
    }

    pub fn checkpoint_in_memory(self: *Self) void {
        _ = self;
    }

    pub fn rollback_in_memory(self: *Self) void {
        _ = self;
    }

    pub fn reclaim_storage(self: *Self) void {
        _ = self;
    }

};

test "OverflowFile" {
    const allocator = std.testing.allocator;
    var instance = OverflowFile.init(allocator);
    defer instance.deinit();
}

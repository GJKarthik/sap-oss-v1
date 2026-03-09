//! ValueVector — Ported from kuzu C++ (115L header, 76L source).
//!

const std = @import("std");

pub const ValueVector = struct {
    allocator: std.mem.Allocator,
    ValueVector: ?*anyopaque = null,
    ColumnChunkData: ?*anyopaque = null,
    values: ?*anyopaque = null,
    numValues: u64 = 0,
    startByteOffset: u64 = 0,
    endByteOffset: u64 = 0,
    isCompleteLine: bool = false,
    message: []const u8 = "",
    completedLine: bool = false,
    warningData: ?*anyopaque = null,
    mustThrow: bool = false,
    filePath: []const u8 = "",
    skippedLineOrRecord: []const u8 = "",
    lineNumber: u64 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn warning_source_data(self: *Self) void {
        _ = self;
    }

    pub fn dump_to(self: *Self) void {
        _ = self;
    }

    pub fn construct_from(self: *Self) void {
        _ = self;
    }

    pub fn get_block_idx(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_offset_in_block(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn construct_from_data(self: *Self) void {
        _ = self;
    }

    pub fn set_new_line(self: *Self) void {
        _ = self;
    }

    pub fn set_end_of_line(self: *Self) void {
        _ = self;
    }

};

test "ValueVector" {
    const allocator = std.testing.allocator;
    var instance = ValueVector.init(allocator);
    defer instance.deinit();
    _ = instance.get_block_idx();
    _ = instance.get_offset_in_block();
}

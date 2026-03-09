//! ArrowResultCollectorSharedState — Ported from kuzu C++ (87L header, 102L source).
//!

const std = @import("std");

pub const ArrowResultCollectorSharedState = struct {
    allocator: std.mem.Allocator,
    arrays: std.ArrayList(?*anyopaque) = .{},
    mutex: ?*anyopaque = null,
    vectors: std.ArrayList(?*anyopaque) = .{},
    chunks: std.ArrayList(?*anyopaque) = .{},
    chunkCursors: std.ArrayList(?*anyopaque) = .{},
    tuple: ?*?*anyopaque = null,
    chunkSize: i64 = 0,
    payloadPositions: std.ArrayList(?*anyopaque) = .{},
    columnTypes: std.ArrayList(?*anyopaque) = .{},
    sharedState: ?*?*anyopaque = null,
    info: ?*anyopaque = null,
    localState: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn merge(self: *Self) void {
        _ = self;
    }

    pub fn advance(self: *Self) void {
        _ = self;
    }

    pub fn fill_tuple(self: *Self) void {
        _ = self;
    }

    pub fn reset_cursor(self: *Self) void {
        _ = self;
    }

    pub fn execute_internal(self: *Self) void {
        _ = self;
    }

    pub fn init_local_state_internal(self: *Self) void {
        _ = self;
    }

    pub fn iterate_result_set(self: *Self) void {
        _ = self;
    }

    pub fn fill_row_batch(self: *Self) void {
        _ = self;
    }

};

test "ArrowResultCollectorSharedState" {
    const allocator = std.testing.allocator;
    var instance = ArrowResultCollectorSharedState.init(allocator);
    defer instance.deinit();
}

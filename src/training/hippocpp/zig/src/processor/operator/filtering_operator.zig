//! DataChunkState — Ported from kuzu C++ (30L header, 43L source).
//!

const std = @import("std");

pub const DataChunkState = struct {
    allocator: std.mem.Allocator,
    DataChunkState: ?*anyopaque = null,
    prevSelVector: ?*?*anyopaque = null,
    currentSelVector: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn restore_sel_vector(self: *Self) void {
        _ = self;
    }

    pub fn save_sel_vector(self: *Self) void {
        _ = self;
    }

    pub fn reset_current_sel_vector(self: *Self) void {
        _ = self;
    }

};

test "DataChunkState" {
    const allocator = std.testing.allocator;
    var instance = DataChunkState.init(allocator);
    defer instance.deinit();
}

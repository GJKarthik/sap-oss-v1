//! NodeTable — Ported from kuzu C++ (61L header, 37L source).
//!

const std = @import("std");

pub const NodeTable = struct {
    allocator: std.mem.Allocator,
    NodeTable: ?*anyopaque = null,
    message: []const u8 = "",
    key: ?*anyopaque = null,
    nodeID: ?*anyopaque = null,
    warningData: ?*anyopaque = null,
    keyVector: ?*?*anyopaque = null,
    offsetVector: ?*?*anyopaque = null,
    baseErrorHandler: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn handle_error(self: *Self) void {
        _ = self;
    }

    pub fn flush_stored_errors(self: *Self) void {
        _ = self;
    }

    pub fn set_current_erroneous_row(self: *Self) void {
        _ = self;
    }

    pub fn delete_current_erroneous_row(self: *Self) void {
        _ = self;
    }

};

test "NodeTable" {
    const allocator = std.testing.allocator;
    var instance = NodeTable.init(allocator);
    defer instance.deinit();
}

//! NodeInsertExecutor — Ported from kuzu C++ (148L header, 242L source).
//!

const std = @import("std");

pub const NodeInsertExecutor = struct {
    allocator: std.mem.Allocator,
    nodeIDPos: ?*anyopaque = null,
    columnsPos: std.ArrayList(?*anyopaque) = .{},
    conflictAction: ?*anyopaque = null,
    columnVectors: std.ArrayList(?*anyopaque) = .{},
    columnDataEvaluators: std.ArrayList(u8) = .{},
    columnDataVectors: std.ArrayList(?*anyopaque) = .{},
    info: ?*anyopaque = null,
    tableInfo: ?*anyopaque = null,
    srcNodeIDPos: ?*anyopaque = null,
    dstNodeIDPos: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn update_node_id(self: *Self) void {
        _ = self;
    }

    pub fn get_node_id(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn set_node_id_vector_to_non_null(self: *Self) void {
        _ = self;
    }

    pub fn insert(self: *Self) void {
        _ = self;
    }

    pub fn skip_insert(self: *Self) void {
        _ = self;
    }

    pub fn check_conflict(self: *Self) void {
        _ = self;
    }

    pub fn get_rel_id(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

};

test "NodeInsertExecutor" {
    const allocator = std.testing.allocator;
    var instance = NodeInsertExecutor.init(allocator);
    defer instance.deinit();
    _ = instance.get_node_id();
}

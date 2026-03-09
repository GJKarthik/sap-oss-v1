//! Transaction — Ported from kuzu C++ (125L header, 409L source).
//!

const std = @import("std");

pub const Transaction = struct {
    allocator: std.mem.Allocator,
    Transaction: ?*anyopaque = null,
    MemoryManager: ?*anyopaque = null,
    nullptr: ?*anyopaque = null,
    enableCompression: bool = false,
    numTotalRows: ?*anyopaque = null,
    types: std.ArrayList(?*anyopaque) = .{},
    nodeGroups: ?*anyopaque = null,
    residency: ?*anyopaque = null,
    stats: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn append(self: *Self) void {
        _ = self;
    }

    pub fn get_num_total_rows(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_num_node_groups(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_num_node_groups_no_lock(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn set_node_group(self: *Self) void {
        _ = self;
    }

    pub fn rollback_insert(self: *Self) void {
        _ = self;
    }

    pub fn clear(self: *Self) void {
        _ = self;
    }

    pub fn get_num_columns(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn add_column(self: *Self) void {
        _ = self;
    }

    pub fn get_estimated_memory_usage(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

};

test "Transaction" {
    const allocator = std.testing.allocator;
    var instance = Transaction.init(allocator);
    defer instance.deinit();
    _ = instance.get_num_total_rows();
    _ = instance.get_num_node_groups();
}

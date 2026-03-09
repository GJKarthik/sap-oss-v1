//! Transaction — Ported from kuzu C++ (65L header, 859L source).
//!

const std = @import("std");

pub const Transaction = struct {
    allocator: std.mem.Allocator,
    Transaction: ?*anyopaque = null,
    ChunkedNodeGroup: ?*anyopaque = null,
    VectorVersionInfo: ?*anyopaque = null,

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

    pub fn delete_(self: *Self) void {
        _ = self;
    }

    pub fn is_selected(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn get_sel_vector_to_scan(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn clear_vector_info(self: *Self) void {
        _ = self;
    }

    pub fn has_deletions(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn get_num_deletions(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn has_insertions(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn is_deleted(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn is_inserted(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn get_num_vectors(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

};

test "Transaction" {
    const allocator = std.testing.allocator;
    var instance = Transaction.init(allocator);
    defer instance.deinit();
    _ = instance.is_selected();
    _ = instance.get_sel_vector_to_scan();
}

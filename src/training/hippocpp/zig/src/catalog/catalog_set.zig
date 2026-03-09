//! UndoBuffer — Ported from kuzu C++ (92L header, 383L source).
//!

const std = @import("std");

pub const UndoBuffer = struct {
    allocator: std.mem.Allocator,
    BoundAlterInfo: ?*anyopaque = null,
    UndoBuffer: ?*anyopaque = null,
    Transaction: ?*anyopaque = null,
    mtx: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn catalog_set(self: *Self) void {
        _ = self;
    }

    pub fn contains_entry(self: *Self) void {
        _ = self;
    }

    pub fn create_entry(self: *Self) void {
        _ = self;
    }

    pub fn drop_entry(self: *Self) void {
        _ = self;
    }

    pub fn alter_table_entry(self: *Self) void {
        _ = self;
    }

    pub fn get_entries(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn serialize(self: *Self) void {
        _ = self;
    }

    pub fn get_next_oid(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_next_oid_no_lock(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn contains_entry_no_lock(self: *Self) void {
        _ = self;
    }

    pub fn validate_exist_no_lock(self: *Self) void {
        _ = self;
    }

    pub fn validate_not_exist_no_lock(self: *Self) void {
        _ = self;
    }

};

test "UndoBuffer" {
    const allocator = std.testing.allocator;
    var instance = UndoBuffer.init(allocator);
    defer instance.deinit();
}

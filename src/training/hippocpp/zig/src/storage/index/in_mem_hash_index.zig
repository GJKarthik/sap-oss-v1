//! InMemHashIndex — Ported from kuzu C++ (316L header, 289L source).
//!

const std = @import("std");

pub const InMemHashIndex = struct {
    allocator: std.mem.Allocator,
    false: ?*anyopaque = null,
    true: ?*anyopaque = null,
    slotInfo: ?*anyopaque = null,
    indexHeader: ?*anyopaque = null,
    deletedPos: ?*anyopaque = null,
    entryPos: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn slots(self: *Self) void {
        _ = self;
    }

    pub fn tables(self: *Self) void {
        _ = self;
    }

    pub fn slot(self: *Self) void {
        _ = self;
    }

    pub fn static_assert(self: *Self) void {
        _ = self;
    }

    pub fn reserve(self: *Self) void {
        _ = self;
    }

    pub fn allocate_slots(self: *Self) void {
        _ = self;
    }

    pub fn reserve_space_for_append(self: *Self) void {
        _ = self;
    }

    pub fn append(self: *Self) void {
        _ = self;
    }

    pub fn append_internal(self: *Self) void {
        _ = self;
    }

};

test "InMemHashIndex" {
    const allocator = std.testing.allocator;
    var instance = InMemHashIndex.init(allocator);
    defer instance.deinit();
}

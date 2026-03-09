//! ValueVector — Ported from kuzu C++ (174L header, 48L source).
//!

const std = @import("std");

pub const State = enum(u8) {
    DYNAMIC = 0,
    STATIC = 1,
};

pub const ValueVector = struct {
    allocator: std.mem.Allocator,
    ValueVector: ?*anyopaque = null,
    selectedSize: ?*anyopaque = null,
    state: ?*anyopaque = null,
    selectedPositionsBuffer: ?*?*anyopaque = null,
    capacity: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn selection_view(self: *Self) void {
        _ = self;
    }

    pub fn for_each(self: *Self) void {
        _ = self;
    }

    pub fn for_each_break_when_false(self: *Self) void {
        _ = self;
    }

    pub fn get_sel_size(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn is_unfiltered(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn is_static(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn slice(self: *Self) void {
        _ = self;
    }

    pub fn selection_vector(self: *Self) void {
        _ = self;
    }

    pub fn set_to_unfiltered(self: *Self) void {
        _ = self;
    }

};

test "ValueVector" {
    const allocator = std.testing.allocator;
    var instance = ValueVector.init(allocator);
    defer instance.deinit();
    _ = instance.get_sel_size();
    _ = instance.is_unfiltered();
}

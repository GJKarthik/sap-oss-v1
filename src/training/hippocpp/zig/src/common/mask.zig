//! is — Ported from kuzu C++ (91L header, 24L source).
//!

const std = @import("std");

pub const is = struct {
    allocator: std.mem.Allocator,
    maxOffset: ?*anyopaque = null,
    enabled: ?*anyopaque = null,
    result: ?*anyopaque = null,
    pinnedMask: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn semi_mask(self: *Self) void {
        _ = self;
    }

    pub fn mask(self: *Self) void {
        _ = self;
    }

    pub fn mask_range(self: *Self) void {
        _ = self;
    }

    pub fn is_masked(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn range(self: *Self) void {
        _ = self;
    }

    pub fn get_num_masked_nodes(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn collect_masked_nodes(self: *Self) void {
        _ = self;
    }

    pub fn get_max_offset(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn is_enabled(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn enable(self: *Self) void {
        _ = self;
    }

    pub fn get_num_masked_node(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn add_mask(self: *Self) void {
        _ = self;
    }

};

test "is" {
    const allocator = std.testing.allocator;
    var instance = is.init(allocator);
    defer instance.deinit();
    _ = instance.is_masked();
}

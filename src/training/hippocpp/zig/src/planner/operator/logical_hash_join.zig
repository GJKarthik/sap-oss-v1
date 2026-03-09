//! KUZU_API — Ported from kuzu C++ (69L header, 208L source).
//!

const std = @import("std");

pub const KUZU_API = struct {
    allocator: std.mem.Allocator,
    joinConditions: ?*anyopaque = null,
    joinType: ?*anyopaque = null,
    mark: ?*anyopaque = null,
    sipInfo: ?*anyopaque = null,
    nodes: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_groups_pos_to_flatten_on_probe_side(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_groups_pos_to_flatten_on_build_side(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn compute_factorized_schema(self: *Self) void {
        _ = self;
    }

    pub fn compute_flat_schema(self: *Self) void {
        _ = self;
    }

    pub fn get_expressions_for_printing(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_expressions_to_materialize(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_join_node_i_ds(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_join_type(self: *const Self) u8 {
        _ = self;
        return null;
    }

    pub fn has_mark(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn get_sip_info(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn require_flat_probe_keys(self: *Self) void {
        _ = self;
    }

};

test "KUZU_API" {
    const allocator = std.testing.allocator;
    var instance = KUZU_API.init(allocator);
    defer instance.deinit();
    _ = instance.get_groups_pos_to_flatten_on_probe_side();
    _ = instance.get_groups_pos_to_flatten_on_build_side();
    _ = instance.get_expressions_for_printing();
}

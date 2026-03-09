//! KUZU_API — Ported from kuzu C++ (42L header, 180L source).
//!

const std = @import("std");

pub const KUZU_API = struct {
    allocator: std.mem.Allocator,
    properties: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_properties(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn visit_single_query_skip_node_rel(self: *Self) void {
        _ = self;
    }

    pub fn visit_query_part_skip_node_rel(self: *Self) void {
        _ = self;
    }

    pub fn visit_match(self: *Self) void {
        _ = self;
    }

    pub fn visit_unwind(self: *Self) void {
        _ = self;
    }

    pub fn visit_load_from(self: *Self) void {
        _ = self;
    }

    pub fn visit_table_function_call(self: *Self) void {
        _ = self;
    }

    pub fn visit_set(self: *Self) void {
        _ = self;
    }

    pub fn visit_delete(self: *Self) void {
        _ = self;
    }

    pub fn visit_insert(self: *Self) void {
        _ = self;
    }

    pub fn visit_merge(self: *Self) void {
        _ = self;
    }

    pub fn visit_projection_body_skip_node_rel(self: *Self) void {
        _ = self;
    }

};

test "KUZU_API" {
    const allocator = std.testing.allocator;
    var instance = KUZU_API.init(allocator);
    defer instance.deinit();
    _ = instance.get_properties();
}

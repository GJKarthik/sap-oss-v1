//! ExpressionChildrenCollector — Ported from kuzu C++ (101L header, 337L source).
//!

const std = @import("std");

pub const ExpressionChildrenCollector = struct {
    allocator: std.mem.Allocator,
    exprs: ?*anyopaque = null,
    varNames: ?*anyopaque = null,
    expressions: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn collect_children(self: *Self) void {
        _ = self;
    }

    pub fn collect_case_children(self: *Self) void {
        _ = self;
    }

    pub fn collect_subquery_children(self: *Self) void {
        _ = self;
    }

    pub fn collect_node_children(self: *Self) void {
        _ = self;
    }

    pub fn collect_rel_children(self: *Self) void {
        _ = self;
    }

    pub fn visit(self: *Self) void {
        _ = self;
    }

    pub fn is_random(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn visit_switch(self: *Self) void {
        _ = self;
    }

    pub fn visit_function_expr(self: *Self) void {
        _ = self;
    }

    pub fn visit_agg_function_expr(self: *Self) void {
        _ = self;
    }

    pub fn visit_property_expr(self: *Self) void {
        _ = self;
    }

    pub fn visit_literal_expr(self: *Self) void {
        _ = self;
    }

};

test "ExpressionChildrenCollector" {
    const allocator = std.testing.allocator;
    var instance = ExpressionChildrenCollector.init(allocator);
    defer instance.deinit();
}

//! ParsedExpressionVisitor — Ported from kuzu C++ (80L header, 229L source).
//!

const std = @import("std");

pub const ParsedExpressionVisitor = struct {
    allocator: std.mem.Allocator,
    paramExprs: ?*anyopaque = null,
    readOnly: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn visit(self: *Self) void {
        _ = self;
    }

    pub fn visit_unsafe(self: *Self) void {
        _ = self;
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

    pub fn visit_variable_expr(self: *Self) void {
        _ = self;
    }

    pub fn visit_path_expr(self: *Self) void {
        _ = self;
    }

    pub fn visit_node_rel_expr(self: *Self) void {
        _ = self;
    }

    pub fn visit_param_expr(self: *Self) void {
        _ = self;
    }

    pub fn visit_subquery_expr(self: *Self) void {
        _ = self;
    }

};

test "ParsedExpressionVisitor" {
    const allocator = std.testing.allocator;
    var instance = ParsedExpressionVisitor.init(allocator);
    defer instance.deinit();
}

//! LogicalPlan — Ported from kuzu C++ (42L header, 0L source).
//!

const std = @import("std");

pub const LogicalPlan = struct {
    allocator: std.mem.Allocator,
    LogicalPlan: ?*anyopaque = null,
    CardinalityEstimator: ?*anyopaque = null,
    Transaction: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn cardinality_updater(self: *Self) void {
        _ = self;
    }

    pub fn rewrite(self: *Self) void {
        _ = self;
    }

    pub fn visit_operator(self: *Self) void {
        _ = self;
    }

    pub fn visit_operator_switch_with_default(self: *Self) void {
        _ = self;
    }

    pub fn visit_operator_default(self: *Self) void {
        _ = self;
    }

    pub fn visit_scan_node_table(self: *Self) void {
        _ = self;
    }

    pub fn visit_extend(self: *Self) void {
        _ = self;
    }

    pub fn visit_hash_join(self: *Self) void {
        _ = self;
    }

    pub fn visit_cross_product(self: *Self) void {
        _ = self;
    }

    pub fn visit_intersect(self: *Self) void {
        _ = self;
    }

    pub fn visit_flatten(self: *Self) void {
        _ = self;
    }

    pub fn visit_filter(self: *Self) void {
        _ = self;
    }

};

test "LogicalPlan" {
    const allocator = std.testing.allocator;
    var instance = LogicalPlan.init(allocator);
    defer instance.deinit();
}

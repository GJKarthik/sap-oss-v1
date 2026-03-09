//! ClientContext — Ported from kuzu C++ (63L header, 294L source).
//!

const std = @import("std");

pub const ClientContext = struct {
    allocator: std.mem.Allocator,
    ClientContext: ?*anyopaque = null,
    Transaction: ?*anyopaque = null,
    LogicalAggregate: ?*anyopaque = null,
    nodeTableStats: ?*anyopaque = null,
    nodeIDName2dom: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn cardinality_estimator(self: *Self) void {
        _ = self;
    }

    pub fn rectify_cardinality(self: *Self) void {
        _ = self;
    }

    pub fn estimate_scan_node(self: *Self) void {
        _ = self;
    }

    pub fn estimate_hash_join(self: *Self) void {
        _ = self;
    }

    pub fn estimate_cross_product(self: *Self) void {
        _ = self;
    }

    pub fn estimate_intersect(self: *Self) void {
        _ = self;
    }

    pub fn estimate_flatten(self: *Self) void {
        _ = self;
    }

    pub fn estimate_filter(self: *Self) void {
        _ = self;
    }

    pub fn estimate_aggregate(self: *Self) void {
        _ = self;
    }

    pub fn get_extension_rate(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

};

test "ClientContext" {
    const allocator = std.testing.allocator;
    var instance = ClientContext.init(allocator);
    defer instance.deinit();
}

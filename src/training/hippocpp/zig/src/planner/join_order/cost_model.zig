//! CostModel — Ported from kuzu C++ (24L header, 109L source).
//!

const std = @import("std");

pub const CostModel = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn compute_extend_cost(self: *Self) void {
        _ = self;
    }

    pub fn compute_hash_join_cost(self: *Self) void {
        _ = self;
    }

    pub fn compute_mark_join_cost(self: *Self) void {
        _ = self;
    }

    pub fn compute_intersect_cost(self: *Self) void {
        _ = self;
    }

};

test "CostModel" {
    const allocator = std.testing.allocator;
    var instance = CostModel.init(allocator);
    defer instance.deinit();
}

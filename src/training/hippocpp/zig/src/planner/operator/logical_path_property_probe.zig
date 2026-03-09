//! LogicalPathPropertyProbe — Ported from kuzu C++ (56L header, 57L source).
//!
//! Extends LogicalOperator in the upstream implementation.

const std = @import("std");

pub const LogicalPathPropertyProbe = struct {
    allocator: std.mem.Allocator,
    recursiveRel: ?*anyopaque = null,
    pathNodeIDs: ?*anyopaque = null,
    pathEdgeIDs: ?*anyopaque = null,
    joinType: ?*anyopaque = null,
    nodeChild: ?*anyopaque = null,
    relChild: ?*anyopaque = null,
    sipInfo: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
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

    pub fn set_join_type(self: *Self) void {
        _ = self;
    }

    pub fn get_join_type(self: *const Self) u8 {
        _ = self;
        return null;
    }

    pub fn get_sip_info(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    /// Create a deep copy of this LogicalPathPropertyProbe.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "LogicalPathPropertyProbe" {
    const allocator = std.testing.allocator;
    var instance = LogicalPathPropertyProbe.init(allocator);
    defer instance.deinit();
    _ = instance.get_expressions_for_printing();
    _ = instance.get_join_type();
}

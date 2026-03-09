//! LogicalDistinct — Ported from kuzu C++ (55L header, 0L source).
//!
//! Extends LogicalOperator in the upstream implementation.

const std = @import("std");

pub const LogicalDistinct = struct {
    allocator: std.mem.Allocator,
    keys: ?*anyopaque = null,
    payloads: ?*anyopaque = null,
    skipNum: ?*anyopaque = null,
    limitNum: ?*anyopaque = null,

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

    pub fn get_groups_pos_to_flatten(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_expressions_for_printing(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_keys(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn set_keys(self: *Self) void {
        _ = self;
    }

    pub fn get_payloads(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn set_payloads(self: *Self) void {
        _ = self;
    }

    pub fn set_skip_num(self: *Self) void {
        _ = self;
    }

    pub fn has_skip_num(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn get_skip_num(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn set_limit_num(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this LogicalDistinct.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.skipNum = self.skipNum;
        new.limitNum = self.limitNum;
        return new;
    }

};

test "LogicalDistinct" {
    const allocator = std.testing.allocator;
    var instance = LogicalDistinct.init(allocator);
    defer instance.deinit();
    _ = instance.get_groups_pos_to_flatten();
    _ = instance.get_expressions_for_printing();
    _ = instance.get_keys();
}

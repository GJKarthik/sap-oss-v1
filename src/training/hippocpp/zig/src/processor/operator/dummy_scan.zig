//! LogicalDummyScan — Ported from kuzu C++ (25L header, 0L source).
//!
//! Extends LogicalOperator in the upstream implementation.

const std = @import("std");

pub const LogicalDummyScan = struct {
    allocator: std.mem.Allocator,

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

    /// Create a deep copy of this LogicalDummyScan.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "LogicalDummyScan" {
    const allocator = std.testing.allocator;
    var instance = LogicalDummyScan.init(allocator);
    defer instance.deinit();
    _ = instance.get_expressions_for_printing();
}

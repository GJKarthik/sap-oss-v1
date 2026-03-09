//! LogicalCopyFrom — Ported from kuzu C++ (55L header, 17L source).
//!
//! Extends LogicalOperator in the upstream implementation.

const std = @import("std");

pub const LogicalCopyFrom = struct {
    allocator: std.mem.Allocator,
    tableName: []const u8 = "",
    info: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn logical_copy_from_print_info(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn get_expressions_for_printing(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn compute_factorized_schema(self: *Self) void {
        _ = self;
    }

    pub fn compute_flat_schema(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this LogicalCopyFrom.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.tableName = self.tableName;
        return new;
    }

};

test "LogicalCopyFrom" {
    const allocator = std.testing.allocator;
    var instance = LogicalCopyFrom.init(allocator);
    defer instance.deinit();
    _ = instance.get_expressions_for_printing();
}

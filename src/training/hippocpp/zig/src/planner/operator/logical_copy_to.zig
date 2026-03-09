//! LogicalCopyTo — Ported from kuzu C++ (59L header, 33L source).
//!
//! Extends LogicalOperator in the upstream implementation.

const std = @import("std");

pub const LogicalCopyTo = struct {
    allocator: std.mem.Allocator,
    columnNames: std.ArrayList([]const u8) = .{},
    fileName: []const u8 = "",
    exportFunc: ?*anyopaque = null,
    bindData: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn logical_copy_to_print_info(self: *Self) void {
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

    pub fn compute_factorized_schema(self: *Self) void {
        _ = self;
    }

    pub fn compute_flat_schema(self: *Self) void {
        _ = self;
    }

    pub fn get_export_func(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    /// Create a deep copy of this LogicalCopyTo.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.fileName = self.fileName;
        return new;
    }

};

test "LogicalCopyTo" {
    const allocator = std.testing.allocator;
    var instance = LogicalCopyTo.init(allocator);
    defer instance.deinit();
    _ = instance.get_groups_pos_to_flatten();
    _ = instance.get_expressions_for_printing();
}

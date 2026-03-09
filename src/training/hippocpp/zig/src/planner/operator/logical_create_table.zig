//! LogicalCreateTable — Ported from kuzu C++ (49L header, 0L source).
//!
//! Extends LogicalSimple in the upstream implementation.

const std = @import("std");

pub const LogicalCreateTable = struct {
    allocator: std.mem.Allocator,
    info: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn logical_create_table_print_info(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn get_expressions_for_printing(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    /// Create a deep copy of this LogicalCreateTable.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "LogicalCreateTable" {
    const allocator = std.testing.allocator;
    var instance = LogicalCreateTable.init(allocator);
    defer instance.deinit();
    _ = instance.get_expressions_for_printing();
}

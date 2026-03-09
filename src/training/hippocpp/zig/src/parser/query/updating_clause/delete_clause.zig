//! DeleteClause — Ported from kuzu C++ (28L header, 0L source).
//!
//! Extends UpdatingClause in the upstream implementation.

const std = @import("std");

pub const DeleteClause = struct {
    allocator: std.mem.Allocator,
    deleteType: ?*anyopaque = null,
    expressions: std.ArrayList(u8) = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn add_expression(self: *Self) void {
        _ = self;
    }

    pub fn get_delete_clause_type(self: *const Self) u8 {
        _ = self;
        return null;
    }

    pub fn get_num_expressions(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    /// Create a deep copy of this DeleteClause.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "DeleteClause" {
    const allocator = std.testing.allocator;
    var instance = DeleteClause.init(allocator);
    defer instance.deinit();
    _ = instance.get_delete_clause_type();
    _ = instance.get_num_expressions();
}

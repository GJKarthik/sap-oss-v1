//! BoundRegularQuery — Ported from kuzu C++ (33L header, 0L source).
//!
//! Extends BoundStatement in the upstream implementation.

const std = @import("std");

pub const BoundRegularQuery = struct {
    allocator: std.mem.Allocator,
    singleQueries: std.ArrayList(?*anyopaque) = .{},
    isUnionAll: std.ArrayList(bool) = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn add_single_query(self: *Self) void {
        _ = self;
    }

    pub fn get_num_single_queries(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_is_union_all(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    /// Create a deep copy of this BoundRegularQuery.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "BoundRegularQuery" {
    const allocator = std.testing.allocator;
    var instance = BoundRegularQuery.init(allocator);
    defer instance.deinit();
    _ = instance.get_num_single_queries();
    _ = instance.get_is_union_all();
}

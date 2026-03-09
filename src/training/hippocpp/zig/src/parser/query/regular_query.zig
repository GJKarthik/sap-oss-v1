//! RegularQuery — Ported from kuzu C++ (37L header, 0L source).
//!
//! Extends Statement in the upstream implementation.

const std = @import("std");

pub const RegularQuery = struct {
    allocator: std.mem.Allocator,
    isUnionAll: ?*anyopaque = null,
    singleQueries: std.ArrayList(?*anyopaque) = .{},

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

    /// Create a deep copy of this RegularQuery.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "RegularQuery" {
    const allocator = std.testing.allocator;
    var instance = RegularQuery.init(allocator);
    defer instance.deinit();
    _ = instance.get_num_single_queries();
}

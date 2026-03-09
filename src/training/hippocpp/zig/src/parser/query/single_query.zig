//! SingleQuery — Ported from kuzu C++ (50L header, 0L source).
//!

const std = @import("std");

pub const SingleQuery = struct {
    allocator: std.mem.Allocator,
    queryParts: std.ArrayList(?*anyopaque) = .{},
    returnClause: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn add_query_part(self: *Self) void {
        _ = self;
    }

    pub fn get_num_query_parts(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_num_updating_clauses(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn add_updating_clause(self: *Self) void {
        _ = self;
    }

    pub fn get_num_reading_clauses(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn add_reading_clause(self: *Self) void {
        _ = self;
    }

    pub fn set_return_clause(self: *Self) void {
        _ = self;
    }

    pub fn has_return_clause(self: *const Self) bool {
        _ = self;
        return false;
    }

};

test "SingleQuery" {
    const allocator = std.testing.allocator;
    var instance = SingleQuery.init(allocator);
    defer instance.deinit();
    _ = instance.get_num_query_parts();
    _ = instance.get_num_updating_clauses();
    _ = instance.get_num_reading_clauses();
}

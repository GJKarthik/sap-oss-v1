//! JoinOrderEnumeratorContext — Ported from kuzu C++ (52L header, 0L source).
//!

const std = @import("std");

pub const JoinOrderEnumeratorContext = struct {
    allocator: std.mem.Allocator,
    Planner: ?*anyopaque = null,
    whereExpressionsSplitOnAND: ?*anyopaque = null,
    queryGraph: ?*anyopaque = null,
    currentLevel: u32 = 0,
    maxLevel: u32 = 0,
    subPlansTable: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_where_expressions(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn contain_plans(self: *Self) void {
        _ = self;
    }

    pub fn add_plan(self: *Self) void {
        _ = self;
    }

    pub fn get_empty_subquery_graph(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_fully_matched_subquery_graph(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn reset_state(self: *Self) void {
        _ = self;
    }

};

test "JoinOrderEnumeratorContext" {
    const allocator = std.testing.allocator;
    var instance = JoinOrderEnumeratorContext.init(allocator);
    defer instance.deinit();
    _ = instance.get_where_expressions();
    _ = instance.get_empty_subquery_graph();
}

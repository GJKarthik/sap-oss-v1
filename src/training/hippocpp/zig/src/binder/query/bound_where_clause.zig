//! BoundWhereClause — graph database engine module.
//!

const std = @import("std");

pub const BoundWhereClause = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_expressions(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn has_aggregation(self: *const Self) bool {
        _ = self;
        return false;
    }

};

test "BoundWhereClause" {
    const allocator = std.testing.allocator;
    var instance = BoundWhereClause.init(allocator);
    defer instance.deinit();
    _ = instance.has_aggregation();
}

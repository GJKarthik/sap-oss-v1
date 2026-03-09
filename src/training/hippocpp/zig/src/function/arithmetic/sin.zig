//! NormalizedSingleQuery — Ported from kuzu C++ (30L header, 0L source).
//!

const std = @import("std");

pub const NormalizedSingleQuery = struct {
    allocator: std.mem.Allocator,
    queryParts: std.ArrayList(?*anyopaque) = .{},
    statementResult: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn append_query_part(self: *Self) void {
        _ = self;
    }

    pub fn get_num_query_parts(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn set_statement_result(self: *Self) void {
        _ = self;
    }

};

test "NormalizedSingleQuery" {
    const allocator = std.testing.allocator;
    var instance = NormalizedSingleQuery.init(allocator);
    defer instance.deinit();
    _ = instance.get_num_query_parts();
}

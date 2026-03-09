//! BoundStatement — Ported from kuzu C++ (42L header, 0L source).
//!

const std = @import("std");

pub const BoundStatement = struct {
    allocator: std.mem.Allocator,
    statementType: ?*anyopaque = null,
    statementResult: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_statement_type(self: *const Self) u8 {
        _ = self;
        return null;
    }

};

test "BoundStatement" {
    const allocator = std.testing.allocator;
    var instance = BoundStatement.init(allocator);
    defer instance.deinit();
    _ = instance.get_statement_type();
}

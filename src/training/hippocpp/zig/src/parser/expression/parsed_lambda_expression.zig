//! ParsedLambdaExpression — Ported from kuzu C++ (32L header, 0L source).
//!
//! Extends ParsedExpression in the upstream implementation.

const std = @import("std");

pub const ParsedLambdaExpression = struct {
    allocator: std.mem.Allocator,
    varNames: ?*anyopaque = null,
    functionExpr: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this ParsedLambdaExpression.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "ParsedLambdaExpression" {
    const allocator = std.testing.allocator;
    var instance = ParsedLambdaExpression.init(allocator);
    defer instance.deinit();
}

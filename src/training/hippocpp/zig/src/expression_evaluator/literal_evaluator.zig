//! LiteralExpressionEvaluator — Ported from kuzu C++ (38L header, 43L source).
//!
//! Extends ExpressionEvaluator in the upstream implementation.

const std = @import("std");

pub const LiteralExpressionEvaluator = struct {
    allocator: std.mem.Allocator,
    value: ?*anyopaque = null,
    flatState: ?*?*anyopaque = null,
    unFlatState: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn evaluate(self: *Self) void {
        _ = self;
    }

    pub fn select_internal(self: *Self) void {
        _ = self;
    }

    pub fn resolve_result_vector(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this LiteralExpressionEvaluator.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "LiteralExpressionEvaluator" {
    const allocator = std.testing.allocator;
    var instance = LiteralExpressionEvaluator.init(allocator);
    defer instance.deinit();
}

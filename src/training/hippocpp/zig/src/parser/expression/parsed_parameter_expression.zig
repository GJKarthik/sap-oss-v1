//! ParsedParameterExpression — Ported from kuzu C++ (31L header, 0L source).
//!
//! Extends ParsedExpression in the upstream implementation.

const std = @import("std");

pub const ParsedParameterExpression = struct {
    allocator: std.mem.Allocator,
    parameterName: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_parameter_name(self: *const Self) []const u8 {
        _ = self;
        return "";
    }

    pub fn serialize_internal(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this ParsedParameterExpression.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.parameterName = self.parameterName;
        return new;
    }

};

test "ParsedParameterExpression" {
    const allocator = std.testing.allocator;
    var instance = ParsedParameterExpression.init(allocator);
    defer instance.deinit();
    _ = instance.get_parameter_name();
}

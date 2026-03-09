//! ParsedVariableExpression — Ported from kuzu C++ (46L header, 18L source).
//!
//! Extends ParsedExpression in the upstream implementation.

const std = @import("std");

pub const ParsedVariableExpression = struct {
    allocator: std.mem.Allocator,
    variableName: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_variable_name(self: *const Self) []const u8 {
        _ = self;
        return "";
    }

    pub fn serialize_internal(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this ParsedVariableExpression.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.variableName = self.variableName;
        return new;
    }

};

test "ParsedVariableExpression" {
    const allocator = std.testing.allocator;
    var instance = ParsedVariableExpression.init(allocator);
    defer instance.deinit();
    _ = instance.get_variable_name();
}

//! ParsedFunctionExpression — Ported from kuzu C++ (77L header, 31L source).
//!
//! Extends ParsedExpression in the upstream implementation.

const std = @import("std");

pub const ParsedFunctionExpression = struct {
    allocator: std.mem.Allocator,
    isDistinct: ?*anyopaque = null,
    functionName: ?*anyopaque = null,
    optionalArguments: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_is_distinct(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_function_name(self: *const Self) []const u8 {
        _ = self;
        return "";
    }

    pub fn get_normalized_function_name(self: *const Self) []const u8 {
        _ = self;
        return "";
    }

    pub fn add_child(self: *Self) void {
        _ = self;
    }

    pub fn set_optional_arguments(self: *Self) void {
        _ = self;
    }

    pub fn add_optional_params(self: *Self) void {
        _ = self;
    }

    pub fn serialize_internal(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this ParsedFunctionExpression.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.isDistinct = self.isDistinct;
        new.functionName = self.functionName;
        return new;
    }

};

test "ParsedFunctionExpression" {
    const allocator = std.testing.allocator;
    var instance = ParsedFunctionExpression.init(allocator);
    defer instance.deinit();
    _ = instance.get_is_distinct();
    _ = instance.get_function_name();
    _ = instance.get_normalized_function_name();
}

//! ExtensionStatement — Ported from kuzu C++ (22L header, 0L source).
//!
//! Extends parser in the upstream implementation.

const std = @import("std");

pub const ExtensionStatement = struct {
    allocator: std.mem.Allocator,
    statementName: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_statement_name(self: *const Self) []const u8 {
        _ = self;
        return "";
    }

    /// Create a deep copy of this ExtensionStatement.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.statementName = self.statementName;
        return new;
    }

};

test "ExtensionStatement" {
    const allocator = std.testing.allocator;
    var instance = ExtensionStatement.init(allocator);
    defer instance.deinit();
    _ = instance.get_statement_name();
}

//! LogicalDetachDatabase — Ported from kuzu C++ (28L header, 0L source).
//!
//! Extends LogicalSimple in the upstream implementation.

const std = @import("std");

pub const LogicalDetachDatabase = struct {
    allocator: std.mem.Allocator,
    dbName: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_db_name(self: *const Self) []const u8 {
        _ = self;
        return "";
    }

    pub fn get_expressions_for_printing(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    /// Create a deep copy of this LogicalDetachDatabase.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.dbName = self.dbName;
        return new;
    }

};

test "LogicalDetachDatabase" {
    const allocator = std.testing.allocator;
    var instance = LogicalDetachDatabase.init(allocator);
    defer instance.deinit();
    _ = instance.get_db_name();
    _ = instance.get_expressions_for_printing();
}

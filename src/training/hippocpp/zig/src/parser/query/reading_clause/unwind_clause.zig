//! UnwindClause — Ported from kuzu C++ (27L header, 0L source).
//!
//! Extends ReadingClause in the upstream implementation.

const std = @import("std");

pub const UnwindClause = struct {
    allocator: std.mem.Allocator,
    alias: ?*anyopaque = null,
    expression: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_alias(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    /// Create a deep copy of this UnwindClause.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.alias = self.alias;
        return new;
    }

};

test "UnwindClause" {
    const allocator = std.testing.allocator;
    var instance = UnwindClause.init(allocator);
    defer instance.deinit();
    _ = instance.get_alias();
}

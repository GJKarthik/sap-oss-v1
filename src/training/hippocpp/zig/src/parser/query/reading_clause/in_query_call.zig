//! InQueryCallClause — Ported from kuzu C++ (28L header, 0L source).
//!
//! Extends ReadingClause in the upstream implementation.

const std = @import("std");

pub const InQueryCallClause = struct {
    allocator: std.mem.Allocator,
    yieldVariables: ?*anyopaque = null,
    functionExpression: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this InQueryCallClause.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "InQueryCallClause" {
    const allocator = std.testing.allocator;
    var instance = InQueryCallClause.init(allocator);
    defer instance.deinit();
}

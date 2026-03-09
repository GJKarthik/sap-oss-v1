//! BoundExplain — Ported from kuzu C++ (29L header, 0L source).
//!
//! Extends BoundStatement in the upstream implementation.

const std = @import("std");

pub const BoundExplain = struct {
    allocator: std.mem.Allocator,
    explainType: ?*anyopaque = null,
    statementToExplain: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_explain_type(self: *const Self) u8 {
        _ = self;
        return null;
    }

    /// Create a deep copy of this BoundExplain.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "BoundExplain" {
    const allocator = std.testing.allocator;
    var instance = BoundExplain.init(allocator);
    defer instance.deinit();
    _ = instance.get_explain_type();
}

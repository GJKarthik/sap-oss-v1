//! RemoveFactorizationRewriter — Ported from kuzu C++ (22L header, 0L source).
//!
//! Extends LogicalOperatorVisitor in the upstream implementation.

const std = @import("std");

pub const RemoveFactorizationRewriter = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn rewrite(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this RemoveFactorizationRewriter.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "RemoveFactorizationRewriter" {
    const allocator = std.testing.allocator;
    var instance = RemoveFactorizationRewriter.init(allocator);
    defer instance.deinit();
}

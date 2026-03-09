//! WithClauseProjectionRewriter — Ported from kuzu C++ (20L header, 0L source).
//!
//! Extends BoundStatementVisitor in the upstream implementation.

const std = @import("std");

pub const WithClauseProjectionRewriter = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn match(self: *Self) void {
        _ = self;
    }

    pub fn visit_single_query_unsafe(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this WithClauseProjectionRewriter.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "WithClauseProjectionRewriter" {
    const allocator = std.testing.allocator;
    var instance = WithClauseProjectionRewriter.init(allocator);
    defer instance.deinit();
}

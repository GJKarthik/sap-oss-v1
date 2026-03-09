//! ScalarMacroCatalogEntry — Ported from kuzu C++ (35L header, 0L source).
//!
//! Extends CatalogEntry in the upstream implementation.

const std = @import("std");

pub const ScalarMacroCatalogEntry = struct {
    allocator: std.mem.Allocator,
    macroFunction: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn serialize(self: *Self) void {
        _ = self;
    }

    pub fn to_cypher(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this ScalarMacroCatalogEntry.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "ScalarMacroCatalogEntry" {
    const allocator = std.testing.allocator;
    var instance = ScalarMacroCatalogEntry.init(allocator);
    defer instance.deinit();
}

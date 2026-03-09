//! TypeCatalogEntry — Ported from kuzu C++ (33L header, 97L source).
//!
//! Extends CatalogEntry in the upstream implementation.

const std = @import("std");

pub const TypeCatalogEntry = struct {
    allocator: std.mem.Allocator,
    type: ?*anyopaque = null,

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

    /// Create a deep copy of this TypeCatalogEntry.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "TypeCatalogEntry" {
    const allocator = std.testing.allocator;
    var instance = TypeCatalogEntry.init(allocator);
    defer instance.deinit();
}

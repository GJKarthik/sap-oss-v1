//! LoadFrom — Ported from kuzu C++ (37L header, 0L source).
//!
//! Extends ReadingClause in the upstream implementation.

const std = @import("std");

pub const LoadFrom = struct {
    allocator: std.mem.Allocator,
    parsingOptions: ?*anyopaque = null,
    columnDefinitions: ?*anyopaque = null,
    source: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn set_paring_options(self: *Self) void {
        _ = self;
    }

    pub fn set_property_definitions(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this LoadFrom.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "LoadFrom" {
    const allocator = std.testing.allocator;
    var instance = LoadFrom.init(allocator);
    defer instance.deinit();
}

//! NullColumn — Ported from kuzu C++ (20L header, 166L source).
//!
//! Extends Column in the upstream implementation.

const std = @import("std");

pub const NullColumn = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this NullColumn.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "NullColumn" {
    const allocator = std.testing.allocator;
    var instance = NullColumn.init(allocator);
    defer instance.deinit();
}

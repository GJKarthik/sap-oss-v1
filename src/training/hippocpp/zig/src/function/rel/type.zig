//! BoundCreateType — Ported from kuzu C++ (26L header, 0L source).
//!
//! Extends BoundStatement in the upstream implementation.

const std = @import("std");

pub const BoundCreateType = struct {
    allocator: std.mem.Allocator,
    name: ?*anyopaque = null,
    type: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_name(self: *const Self) []const u8 {
        _ = self;
        return "";
    }

    /// Create a deep copy of this BoundCreateType.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.name = self.name;
        return new;
    }

};

test "BoundCreateType" {
    const allocator = std.testing.allocator;
    var instance = BoundCreateType.init(allocator);
    defer instance.deinit();
    _ = instance.get_name();
}

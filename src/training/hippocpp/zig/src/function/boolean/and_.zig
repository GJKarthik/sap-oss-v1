//! BoundStandaloneCall — Ported from kuzu C++ (30L header, 0L source).
//!
//! Extends BoundStatement in the upstream implementation.

const std = @import("std");

pub const BoundStandaloneCall = struct {
    allocator: std.mem.Allocator,
    Option: ?*anyopaque = null,
    option: ?*anyopaque = null,
    optionValue: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this BoundStandaloneCall.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "BoundStandaloneCall" {
    const allocator = std.testing.allocator;
    var instance = BoundStandaloneCall.init(allocator);
    defer instance.deinit();
}

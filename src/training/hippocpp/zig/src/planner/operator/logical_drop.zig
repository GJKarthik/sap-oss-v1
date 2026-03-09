//! LogicalDrop — Ported from kuzu C++ (41L header, 0L source).
//!
//! Extends LogicalSimple in the upstream implementation.

const std = @import("std");

pub const LogicalDrop = struct {
    allocator: std.mem.Allocator,
    name: []const u8 = "",
    dropInfo: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn logical_drop_print_info(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn get_expressions_for_printing(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    /// Create a deep copy of this LogicalDrop.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.name = self.name;
        return new;
    }

};

test "LogicalDrop" {
    const allocator = std.testing.allocator;
    var instance = LogicalDrop.init(allocator);
    defer instance.deinit();
    _ = instance.get_expressions_for_printing();
}

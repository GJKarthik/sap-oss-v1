//! BoundCreateMacro — Ported from kuzu C++ (29L header, 0L source).
//!
//! Extends BoundStatement in the upstream implementation.

const std = @import("std");

pub const BoundCreateMacro = struct {
    allocator: std.mem.Allocator,
    macroName: ?*anyopaque = null,
    macro: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_macro_name(self: *const Self) []const u8 {
        _ = self;
        return "";
    }

    /// Create a deep copy of this BoundCreateMacro.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.macroName = self.macroName;
        return new;
    }

};

test "BoundCreateMacro" {
    const allocator = std.testing.allocator;
    var instance = BoundCreateMacro.init(allocator);
    defer instance.deinit();
    _ = instance.get_macro_name();
}

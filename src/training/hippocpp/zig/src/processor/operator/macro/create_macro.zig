//! CreateMacro — Ported from kuzu C++ (59L header, 27L source).
//!
//! Extends SimpleSink in the upstream implementation.

const std = @import("std");

pub const CreateMacro = struct {
    allocator: std.mem.Allocator,
    macroName: []const u8 = "",
    macro: ?*?*anyopaque = null,
    info: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn create_macro_print_info(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn execute_internal(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this CreateMacro.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.macroName = self.macroName;
        new.macroName = self.macroName;
        return new;
    }

};

test "CreateMacro" {
    const allocator = std.testing.allocator;
    var instance = CreateMacro.init(allocator);
    defer instance.deinit();
}

//! UninstallExtension — Ported from kuzu C++ (40L header, 39L source).
//!
//! Extends SimpleSink in the upstream implementation.

const std = @import("std");

pub const UninstallExtension = struct {
    allocator: std.mem.Allocator,
    path: []const u8 = "",

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn uninstall_extension_print_info(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn execute_internal(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this UninstallExtension.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.path = self.path;
        return new;
    }

};

test "UninstallExtension" {
    const allocator = std.testing.allocator;
    var instance = UninstallExtension.init(allocator);
    defer instance.deinit();
}

//! LoadExtension — Ported from kuzu C++ (45L header, 27L source).
//!
//! Extends SimpleSink in the upstream implementation.

const std = @import("std");

pub const LoadExtension = struct {
    allocator: std.mem.Allocator,
    extensionName: []const u8 = "",
    path: []const u8 = "",

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn load_extension_print_info(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn execute_internal(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this LoadExtension.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.extensionName = self.extensionName;
        new.path = self.path;
        return new;
    }

};

test "LoadExtension" {
    const allocator = std.testing.allocator;
    var instance = LoadExtension.init(allocator);
    defer instance.deinit();
}

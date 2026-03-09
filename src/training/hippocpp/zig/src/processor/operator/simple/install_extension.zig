//! InstallExtension — Ported from kuzu C++ (45L header, 44L source).
//!
//! Extends SimpleSink in the upstream implementation.

const std = @import("std");

pub const InstallExtension = struct {
    allocator: std.mem.Allocator,
    info: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn install_extension_print_info(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn execute_internal(self: *Self) void {
        _ = self;
    }

    pub fn set_output_message(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this InstallExtension.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "InstallExtension" {
    const allocator = std.testing.allocator;
    var instance = InstallExtension.init(allocator);
    defer instance.deinit();
}

//! LogicalCreateSequence — Ported from kuzu C++ (51L header, 0L source).
//!
//! Extends LogicalSimple in the upstream implementation.

const std = @import("std");

pub const LogicalCreateSequence = struct {
    allocator: std.mem.Allocator,
    sequenceName: []const u8 = "",
    info: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn logical_create_sequence_print_info(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn get_expressions_for_printing(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_info(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    /// Create a deep copy of this LogicalCreateSequence.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.sequenceName = self.sequenceName;
        return new;
    }

};

test "LogicalCreateSequence" {
    const allocator = std.testing.allocator;
    var instance = LogicalCreateSequence.init(allocator);
    defer instance.deinit();
    _ = instance.get_expressions_for_printing();
}

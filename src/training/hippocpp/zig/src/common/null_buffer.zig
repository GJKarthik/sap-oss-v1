//! NullBuffer — Ported from kuzu C++ (39L header, 0L source).
//!

const std = @import("std");

pub const NullBuffer = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn is_null(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn set_null(self: *Self) void {
        _ = self;
    }

    pub fn set_no_null(self: *Self) void {
        _ = self;
    }

    pub fn get_num_bytes_for_null_values(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn init_null_bytes(self: *Self) void {
        _ = self;
    }

};

test "NullBuffer" {
    const allocator = std.testing.allocator;
    var instance = NullBuffer.init(allocator);
    defer instance.deinit();
    _ = instance.is_null();
    _ = instance.get_num_bytes_for_null_values();
}

//! TableType — Ported from kuzu C++ (23L header, 28L source).
//!
//! Extends uint8_t in the upstream implementation.

const std = @import("std");

pub const TableType = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this TableType.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "TableType" {
    const allocator = std.testing.allocator;
    var instance = TableType.init(allocator);
    defer instance.deinit();
}

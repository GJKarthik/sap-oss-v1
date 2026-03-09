//! ZoneMapCheckResult — Ported from kuzu C++ (14L header, 0L source).
//!
//! Extends uint8_t in the upstream implementation.

const std = @import("std");

pub const ZoneMapCheckResult = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this ZoneMapCheckResult.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "ZoneMapCheckResult" {
    const allocator = std.testing.allocator;
    var instance = ZoneMapCheckResult.init(allocator);
    defer instance.deinit();
}

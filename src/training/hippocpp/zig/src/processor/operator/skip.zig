//! Skip — Ported from kuzu C++ (56L header, 61L source).
//!
//! Extends PhysicalOperator in the upstream implementation.

const std = @import("std");

pub const Skip = struct {
    allocator: std.mem.Allocator,
    number: u64 = 0,
    skipNumber: u64 = 0,
    counter: ?*?*anyopaque = null,
    dataChunkToSelectPos: u32 = 0,
    dataChunkToSelect: ?*?*anyopaque = null,
    dataChunksPosInScope: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn skip_print_info(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn init_local_state_internal(self: *Self) void {
        _ = self;
    }

    pub fn get_next_tuples_internal(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    /// Create a deep copy of this Skip.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.number = self.number;
        new.skipNumber = self.skipNumber;
        new.dataChunkToSelectPos = self.dataChunkToSelectPos;
        return new;
    }

};

test "Skip" {
    const allocator = std.testing.allocator;
    var instance = Skip.init(allocator);
    defer instance.deinit();
    _ = instance.get_next_tuples_internal();
}

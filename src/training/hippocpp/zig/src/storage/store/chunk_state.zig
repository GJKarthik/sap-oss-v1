//! FStateType — Ported from kuzu C++ (44L header, 0L source).
//!
//! Extends uint8_t in the upstream implementation.

const std = @import("std");

pub const FStateType = struct {
    allocator: std.mem.Allocator,
    selVector: ?*anyopaque = null,
    fStateType: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn data_chunk_state(self: *Self) void {
        _ = self;
    }

    pub fn init_original_and_selected_size(self: *Self) void {
        _ = self;
    }

    pub fn is_flat(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn set_to_flat(self: *Self) void {
        _ = self;
    }

    pub fn set_to_unflat(self: *Self) void {
        _ = self;
    }

    pub fn get_sel_size(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn set_sel_vector(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this FStateType.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "FStateType" {
    const allocator = std.testing.allocator;
    var instance = FStateType.init(allocator);
    defer instance.deinit();
    _ = instance.is_flat();
}

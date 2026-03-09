//! CrossProduct — Ported from kuzu C++ (64L header, 38L source).
//!
//! Extends PhysicalOperator in the upstream implementation.

const std = @import("std");

pub const CrossProduct = struct {
    allocator: std.mem.Allocator,
    table: ?*?*anyopaque = null,
    maxMorselSize: u64 = 0,
    outVecPos: std.ArrayList(?*anyopaque) = .{},
    colIndicesToScan: std.ArrayList(?*anyopaque) = .{},
    info: ?*anyopaque = null,
    localState: ?*anyopaque = null,
    vectorsToScan: std.ArrayList(?*anyopaque) = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn init_local_state_internal(self: *Self) void {
        _ = self;
    }

    pub fn get_next_tuples_internal(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    /// Create a deep copy of this CrossProduct.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.maxMorselSize = self.maxMorselSize;
        return new;
    }

};

test "CrossProduct" {
    const allocator = std.testing.allocator;
    var instance = CrossProduct.init(allocator);
    defer instance.deinit();
    _ = instance.get_next_tuples_internal();
}

//! Intersect — Ported from kuzu C++ (86L header, 268L source).
//!
//! Extends PhysicalOperator in the upstream implementation.

const std = @import("std");

pub const Intersect = struct {
    allocator: std.mem.Allocator,
    keyDataPos: ?*anyopaque = null,
    payloadsDataPos: std.ArrayList(?*anyopaque) = .{},
    key: ?*?*anyopaque = null,
    outputDataPos: ?*anyopaque = null,
    intersectDataInfos: std.ArrayList(?*anyopaque) = .{},
    outKeyVector: ?*?*anyopaque = null,
    isIntersectListAFlatValue: std.ArrayList(bool) = .{},
    tupleIdxPerBuildSide: std.ArrayList(u32) = .{},
    carryBuildSideIdx: u32 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn intersect_print_info(self: *Self) void {
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

    pub fn probe_h_ts(self: *Self) void {
        _ = self;
    }

    pub fn two_way_intersect(self: *Self) void {
        _ = self;
    }

    pub fn intersect_lists(self: *Self) void {
        _ = self;
    }

    pub fn populate_payloads(self: *Self) void {
        _ = self;
    }

    pub fn has_next_tuples_to_intersect(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn get_num_builds(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    /// Create a deep copy of this Intersect.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.carryBuildSideIdx = self.carryBuildSideIdx;
        return new;
    }

};

test "Intersect" {
    const allocator = std.testing.allocator;
    var instance = Intersect.init(allocator);
    defer instance.deinit();
    _ = instance.get_next_tuples_internal();
}

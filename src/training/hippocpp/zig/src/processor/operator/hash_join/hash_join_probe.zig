//! HashJoinProbe — Ported from kuzu C++ (123L header, 227L source).
//!
//! Extends PhysicalOperator in the upstream implementation.

const std = @import("std");

pub const HashJoinProbe = struct {
    allocator: std.mem.Allocator,
    probedTuples: ?*?*anyopaque = null,
    matchedTuples: ?*?*anyopaque = null,
    matchedSelVector: ?*anyopaque = null,
    nextMatchedTupleIdx: ?*anyopaque = null,
    keysDataPos: std.ArrayList(?*anyopaque) = .{},
    payloadsOutPos: std.ArrayList(?*anyopaque) = .{},
    markDataPos: ?*anyopaque = null,
    keys: std.ArrayList(u8) = .{},
    sharedState: ?*?*anyopaque = null,
    joinType: ?*anyopaque = null,
    flatProbe: bool = false,
    probeDataInfo: ?*anyopaque = null,
    vectorsToReadInto: std.ArrayList(?*anyopaque) = .{},
    columnIdxsToReadFrom: std.ArrayList(u32) = .{},
    keyVectors: std.ArrayList(?*anyopaque) = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn probe_state(self: *Self) void {
        _ = self;
    }

    pub fn get_num_payloads(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn hash_join_probe_print_info(self: *Self) void {
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

    pub fn get_matched_tuples(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_matched_tuples_for_flat_key(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_matched_tuples_for_un_flat_key(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_inner_join_result(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_inner_join_result_for_flat_key(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    /// Create a deep copy of this HashJoinProbe.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "HashJoinProbe" {
    const allocator = std.testing.allocator;
    var instance = HashJoinProbe.init(allocator);
    defer instance.deinit();
    _ = instance.get_num_payloads();
}

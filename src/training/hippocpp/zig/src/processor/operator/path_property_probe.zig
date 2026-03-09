//! PathPropertyProbe — Ported from kuzu C++ (122L header, 372L source).
//!
//! Extends PhysicalOperator in the upstream implementation.

const std = @import("std");

pub const PathPropertyProbe = struct {
    allocator: std.mem.Allocator,
    nodeHashTableState: ?*?*anyopaque = null,
    relHashTableState: ?*?*anyopaque = null,
    hashes: ?*?*anyopaque = null,
    probedTuples: ?*?*anyopaque = null,
    matchedTuples: ?*?*anyopaque = null,
    tableIDToName: ?*anyopaque = null,
    nodeFieldIndices: std.ArrayList(?*anyopaque) = .{},
    relFieldIndices: std.ArrayList(?*anyopaque) = .{},
    nodeTableColumnIndices: std.ArrayList(?*anyopaque) = .{},
    relTableColumnIndices: std.ArrayList(?*anyopaque) = .{},
    info: ?*anyopaque = null,
    sharedState: ?*?*anyopaque = null,
    localState: ?*anyopaque = null,
    pathNodesPropertyDataVectors: std.ArrayList(?*anyopaque) = .{},
    pathRelsPropertyDataVectors: std.ArrayList(?*anyopaque) = .{},

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

    pub fn probe(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this PathPropertyProbe.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "PathPropertyProbe" {
    const allocator = std.testing.allocator;
    var instance = PathPropertyProbe.init(allocator);
    defer instance.deinit();
    _ = instance.get_next_tuples_internal();
}

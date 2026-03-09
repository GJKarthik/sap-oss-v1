//! UnionAllScanSharedState — Ported from kuzu C++ (97L header, 0L source).
//!

const std = @import("std");

pub const UnionAllScanSharedState = struct {
    allocator: std.mem.Allocator,
    expressions: std.ArrayList(u8) = .{},
    outputPositions: std.ArrayList(?*anyopaque) = .{},
    columnIndices: std.ArrayList(?*anyopaque) = .{},
    startTupleIdx: u64 = 0,
    numTuples: u64 = 0,
    mtx: ?*anyopaque = null,
    maxMorselSize: u64 = 0,
    tableIdx: u64 = 0,
    nextTupleIdxToScan: u64 = 0,
    true: ?*anyopaque = null,
    info: ?*anyopaque = null,
    sharedState: ?*?*anyopaque = null,
    vectors: std.ArrayList(?*anyopaque) = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn union_all_scan_print_info(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn is_source(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn init_local_state_internal(self: *Self) void {
        _ = self;
    }

    pub fn get_next_tuples_internal(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

};

test "UnionAllScanSharedState" {
    const allocator = std.testing.allocator;
    var instance = UnionAllScanSharedState.init(allocator);
    defer instance.deinit();
    _ = instance.is_source();
}

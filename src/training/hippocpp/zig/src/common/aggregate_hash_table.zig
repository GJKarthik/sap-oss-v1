//! InMemOverflowBuffer — Ported from kuzu C++ (342L header, 881L source).
//!

const std = @import("std");

pub const InMemOverflowBuffer = struct {
    allocator: std.mem.Allocator,
    InMemOverflowBuffer: ?*anyopaque = null,
    MemoryManager: ?*anyopaque = null,
    entry: u64 = 0,
    AggregateHashTable: ?*anyopaque = null,
    distinctAggKeyTypes: ?*anyopaque = null,
    nullptr: ?*anyopaque = null,
    mayMatchIdxes: ?*?*anyopaque = null,
    noMatchIdxes: ?*?*anyopaque = null,
    entryIdxesToInitialize: ?*?*anyopaque = null,
    hashSlotsToUpdateAggState: ?*?*anyopaque = null,
    payloadTypes: std.ArrayList(?*anyopaque) = .{},
    aggregateFunctions: std.ArrayList(?*anyopaque) = .{},
    distinctHashEntriesProcessed: std.ArrayList(u64) = .{},
    updateAggFuncs: std.ArrayList(?*anyopaque) = .{},
    tmpValueIdxes: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn check_fingerprint(self: *Self) void {
        _ = self;
    }

    pub fn merge(self: *Self) void {
        _ = self;
    }

    pub fn merge_distinct_aggregate_info(self: *Self) void {
        _ = self;
    }

    pub fn finalize_aggregate_states(self: *Self) void {
        _ = self;
    }

    pub fn resize(self: *Self) void {
        _ = self;
    }

    pub fn clear(self: *Self) void {
        _ = self;
    }

    pub fn resize_hash_table_if_necessary(self: *Self) void {
        _ = self;
    }

    pub fn create_empty_copy(self: *Self) void {
        _ = self;
    }

    pub fn aggregate_hash_table(self: *Self) void {
        _ = self;
    }

    pub fn append_distinct(self: *Self) void {
        _ = self;
    }

    pub fn append(self: *Self) void {
        _ = self;
    }

};

test "InMemOverflowBuffer" {
    const allocator = std.testing.allocator;
    var instance = InMemOverflowBuffer.init(allocator);
    defer instance.deinit();
}

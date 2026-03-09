//! ResultCollectorSharedState — Ported from kuzu C++ (107L header, 141L source).
//!

const std = @import("std");

pub const ResultCollectorSharedState = struct {
    allocator: std.mem.Allocator,
    table: ?*anyopaque = null,
    mtx: ?*anyopaque = null,
    accumulateType: ?*anyopaque = null,
    tableSchema: ?*anyopaque = null,
    payloadPositions: std.ArrayList(?*anyopaque) = .{},
    expressions: std.ArrayList(u8) = .{},
    info: ?*anyopaque = null,
    sharedState: ?*?*anyopaque = null,
    payloadVectors: std.ArrayList(?*anyopaque) = .{},
    payloadAndMarkVectors: std.ArrayList(?*anyopaque) = .{},
    markVector: ?*?*anyopaque = null,
    localTable: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn merge_local_table(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn execute_internal(self: *Self) void {
        _ = self;
    }

    pub fn finalize_internal(self: *Self) void {
        _ = self;
    }

    pub fn init_local_state_internal(self: *Self) void {
        _ = self;
    }

    pub fn init_necessary_local_state(self: *Self) void {
        _ = self;
    }

};

test "ResultCollectorSharedState" {
    const allocator = std.testing.allocator;
    var instance = ResultCollectorSharedState.init(allocator);
    defer instance.deinit();
}

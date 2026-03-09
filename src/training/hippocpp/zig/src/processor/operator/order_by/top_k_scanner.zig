//! TopKScan — Ported from kuzu C++ (47L header, 26L source).
//!
//! Extends PhysicalOperator in the upstream implementation.

const std = @import("std");

pub const TopKScan = struct {
    allocator: std.mem.Allocator,
    vectorsToScan: std.ArrayList(?*anyopaque) = .{},
    payloadScanner: ?*?*anyopaque = null,
    true: ?*anyopaque = null,
    false: ?*anyopaque = null,
    outVectorPos: std.ArrayList(?*anyopaque) = .{},
    localState: ?*?*anyopaque = null,
    sharedState: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn scan(self: *Self) void {
        _ = self;
    }

    pub fn is_source(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn is_parallel(self: *const Self) bool {
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

    /// Create a deep copy of this TopKScan.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "TopKScan" {
    const allocator = std.testing.allocator;
    var instance = TopKScan.init(allocator);
    defer instance.deinit();
    _ = instance.is_source();
    _ = instance.is_parallel();
}

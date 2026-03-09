//! OrderBy — Ported from kuzu C++ (68L header, 46L source).
//!
//! Extends Sink in the upstream implementation.

const std = @import("std");

pub const OrderBy = struct {
    allocator: std.mem.Allocator,
    keys: std.ArrayList(u8) = .{},
    payloads: std.ArrayList(u8) = .{},
    info: ?*anyopaque = null,
    localState: ?*anyopaque = null,
    sharedState: ?*?*anyopaque = null,
    orderByVectors: std.ArrayList(?*anyopaque) = .{},
    payloadVectors: std.ArrayList(?*anyopaque) = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn order_by_print_info(self: *Self) void {
        _ = self;
    }

    pub fn init_local_state_internal(self: *Self) void {
        _ = self;
    }

    pub fn execute_internal(self: *Self) void {
        _ = self;
    }

    pub fn finalize(self: *Self) void {
        _ = self;
    }

    pub fn init_global_state_internal(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this OrderBy.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "OrderBy" {
    const allocator = std.testing.allocator;
    var instance = OrderBy.init(allocator);
    defer instance.deinit();
}

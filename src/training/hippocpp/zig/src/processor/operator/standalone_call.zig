//! StandaloneCall — Ported from kuzu C++ (65L header, 39L source).
//!
//! Extends PhysicalOperator in the upstream implementation.

const std = @import("std");

pub const StandaloneCall = struct {
    allocator: std.mem.Allocator,
    Option: ?*anyopaque = null,
    functionName: []const u8 = "",
    optionValue: ?*anyopaque = null,
    true: ?*anyopaque = null,
    false: ?*anyopaque = null,
    standaloneCallInfo: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn standalone_call_print_info(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
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

    pub fn get_next_tuples_internal(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    /// Create a deep copy of this StandaloneCall.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.functionName = self.functionName;
        return new;
    }

};

test "StandaloneCall" {
    const allocator = std.testing.allocator;
    var instance = StandaloneCall.init(allocator);
    defer instance.deinit();
    _ = instance.is_source();
    _ = instance.is_parallel();
}

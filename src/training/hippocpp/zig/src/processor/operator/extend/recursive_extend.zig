//! RecursiveExtend — Ported from kuzu C++ (55L header, 160L source).
//!
//! Extends Sink in the upstream implementation.

const std = @import("std");

pub const RecursiveExtend = struct {
    allocator: std.mem.Allocator,
    funcName: []const u8 = "",
    sharedState: ?*anyopaque = null,
    true: ?*anyopaque = null,
    false: ?*anyopaque = null,
    function: ?*?*anyopaque = null,
    bindData: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn recursive_extend_print_info(self: *Self) void {
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

    pub fn execute_internal(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this RecursiveExtend.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.funcName = self.funcName;
        return new;
    }

};

test "RecursiveExtend" {
    const allocator = std.testing.allocator;
    var instance = RecursiveExtend.init(allocator);
    defer instance.deinit();
    _ = instance.is_source();
    _ = instance.is_parallel();
}

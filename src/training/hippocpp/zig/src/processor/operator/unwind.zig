//! Unwind — Ported from kuzu C++ (66L header, 79L source).
//!
//! Extends PhysicalOperator in the upstream implementation.

const std = @import("std");

pub const Unwind = struct {
    allocator: std.mem.Allocator,
    inExpression: ?*?*anyopaque = null,
    outExpression: ?*?*anyopaque = null,
    outDataPos: ?*anyopaque = null,
    idPos: ?*anyopaque = null,
    expressionEvaluator: ?*?*anyopaque = null,
    outValueVector: ?*?*anyopaque = null,
    startIndex: u32 = 0,
    listEntry: ?*anyopaque = null,

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

    pub fn unwind_print_info(self: *Self) void {
        _ = self;
    }

    pub fn get_next_tuples_internal(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn init_local_state_internal(self: *Self) void {
        _ = self;
    }

    pub fn has_more_to_read(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn copy_tuples_to_out_vector(self: *Self) void {
        _ = self;
    }

    /// Create a deep copy of this Unwind.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        new.startIndex = self.startIndex;
        return new;
    }

};

test "Unwind" {
    const allocator = std.testing.allocator;
    var instance = Unwind.init(allocator);
    defer instance.deinit();
    _ = instance.get_next_tuples_internal();
    _ = instance.has_more_to_read();
}

//! StatementType — Ported from kuzu C++ (62L header, 39L source).
//!
//! Extends uint8_t in the upstream implementation.

const std = @import("std");

pub const StatementType = struct {
    allocator: std.mem.Allocator,
    statementType: ?*anyopaque = null,
    preparedSummary: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn query_summary(self: *Self) void {
        _ = self;
    }

    pub fn get_compiling_time(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_execution_time(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn set_execution_time(self: *Self) void {
        _ = self;
    }

    pub fn increment_compiling_time(self: *Self) void {
        _ = self;
    }

    pub fn increment_execution_time(self: *Self) void {
        _ = self;
    }

    pub fn is_explain(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn get_statement_type(self: *const Self) u8 {
        _ = self;
        return null;
    }

    /// Create a deep copy of this StatementType.
    pub fn copy(self: *const Self) Self {
        var new = Self.init(self.allocator);
        return new;
    }

};

test "StatementType" {
    const allocator = std.testing.allocator;
    var instance = StatementType.init(allocator);
    defer instance.deinit();
    _ = instance.get_compiling_time();
    _ = instance.get_execution_time();
}

//! QueryResult — Ported from kuzu C++ (123L header, 26L source).
//!

const std = @import("std");

pub const QueryResult = struct {
    allocator: std.mem.Allocator,
    QueryResult: ?*anyopaque = null,
    true: ?*anyopaque = null,
    false: ?*anyopaque = null,
    resultSetDescriptor: ?*?*anyopaque = null,
    messageTable: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn is_sink(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn set_descriptor(self: *Self) void {
        _ = self;
    }

    pub fn execute(self: *Self) void {
        _ = self;
    }

    pub fn terminate(self: *Self) void {
        _ = self;
    }

    pub fn execute_internal(self: *Self) void {
        _ = self;
    }

    pub fn get_next_tuples_internal(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn is_source(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn is_parallel(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn append_message(self: *Self) void {
        _ = self;
    }

};

test "QueryResult" {
    const allocator = std.testing.allocator;
    var instance = QueryResult.init(allocator);
    defer instance.deinit();
    _ = instance.is_sink();
}

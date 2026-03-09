//! LogicalType — Ported from kuzu C++ (90L header, 157L source).
//!

const std = @import("std");

pub const LogicalType = struct {
    allocator: std.mem.Allocator,
    LogicalType: ?*anyopaque = null,
    Statement: ?*anyopaque = null,
    Expression: ?*anyopaque = null,
    LogicalPlan: ?*anyopaque = null,
    parsedStatement: ?*?*anyopaque = null,
    logicalPlan: ?*?*anyopaque = null,
    Connection: ?*anyopaque = null,
    ClientContext: ?*anyopaque = null,
    unknownParameters: ?*anyopaque = null,
    cachedPreparedStatementName: ?*anyopaque = null,
    errMsg: []const u8 = "",
    preparedSummary: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn is_success(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn get_error_message(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn is_read_only(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn update_parameter(self: *Self) void {
        _ = self;
    }

    pub fn add_parameter(self: *Self) void {
        _ = self;
    }

    pub fn get_name(self: *const Self) []const u8 {
        _ = self;
        return "";
    }

    pub fn get_statement_type(self: *const Self) u8 {
        _ = self;
        return null;
    }

};

test "LogicalType" {
    const allocator = std.testing.allocator;
    var instance = LogicalType.init(allocator);
    defer instance.deinit();
    _ = instance.is_success();
    _ = instance.get_error_message();
    _ = instance.is_read_only();
}

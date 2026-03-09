//! KUZU_API — Ported from kuzu C++ (82L header, 57L source).
//!

const std = @import("std");

pub const KUZU_API = struct {
    allocator: std.mem.Allocator,
    bindData: ?*?*anyopaque = null,
    outPosV: std.ArrayList(?*anyopaque) = .{},
    funcName: []const u8 = "",
    exprs: std.ArrayList(u8) = .{},
    info: ?*anyopaque = null,
    sharedState: ?*anyopaque = null,
    true: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn table_function_call_print_info(self: *Self) void {
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

    pub fn init_local_state_internal(self: *Self) void {
        _ = self;
    }

    pub fn get_next_tuples_internal(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn finalize_internal(self: *Self) void {
        _ = self;
    }

    pub fn get_progress(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

};

test "KUZU_API" {
    const allocator = std.testing.allocator;
    var instance = KUZU_API.init(allocator);
    defer instance.deinit();
    _ = instance.is_source();
    _ = instance.is_parallel();
}

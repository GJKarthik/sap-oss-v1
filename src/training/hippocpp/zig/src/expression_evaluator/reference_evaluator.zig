//! ClientContext — Ported from kuzu C++ (39L header, 34L source).
//!

const std = @import("std");

pub const ClientContext = struct {
    allocator: std.mem.Allocator,
    ClientContext: ?*anyopaque = null,
    dataPos: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn evaluate(self: *Self) void {
        _ = self;
    }

    pub fn select_internal(self: *Self) void {
        _ = self;
    }

    pub fn resolve_result_vector(self: *Self) void {
        _ = self;
    }

};

test "ClientContext" {
    const allocator = std.testing.allocator;
    var instance = ClientContext.init(allocator);
    defer instance.deinit();
}

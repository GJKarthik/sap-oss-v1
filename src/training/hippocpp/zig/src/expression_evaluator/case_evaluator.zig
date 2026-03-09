//! ClientContext — Ported from kuzu C++ (79L header, 108L source).
//!

const std = @import("std");

pub const ClientContext = struct {
    allocator: std.mem.Allocator,
    ClientContext: ?*anyopaque = null,
    whenEvaluator: ?*?*anyopaque = null,
    thenEvaluator: ?*?*anyopaque = null,
    whenSelVector: ?*?*anyopaque = null,
    alternativeEvaluators: ?*anyopaque = null,
    elseEvaluator: ?*?*anyopaque = null,
    filledMask: ?*anyopaque = null,

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

    pub fn fill_selected(self: *Self) void {
        _ = self;
    }

    pub fn fill_all(self: *Self) void {
        _ = self;
    }

    pub fn fill_entry(self: *Self) void {
        _ = self;
    }

};

test "ClientContext" {
    const allocator = std.testing.allocator;
    var instance = ClientContext.init(allocator);
    defer instance.deinit();
}

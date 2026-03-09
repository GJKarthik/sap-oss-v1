//! LimitPushDownOptimizer — Ported from kuzu C++ (23L header, 0L source).
//!

const std = @import("std");

pub const LimitPushDownOptimizer = struct {
    allocator: std.mem.Allocator,
    skipNumber: u64 = 0,
    limitNumber: u64 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn rewrite(self: *Self) void {
        _ = self;
    }

    pub fn visit_operator(self: *Self) void {
        _ = self;
    }

};

test "LimitPushDownOptimizer" {
    const allocator = std.testing.allocator;
    var instance = LimitPushDownOptimizer.init(allocator);
    defer instance.deinit();
}

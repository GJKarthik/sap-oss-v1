//! NodeRelEvaluator — graph database engine module.
//!

const std = @import("std");

pub const NodeRelEvaluator = struct {
    allocator: std.mem.Allocator,
    result_vector: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Perform evaluate operation.
    pub fn evaluate(self: *Self) !void {
        _ = self;
    }

    pub fn init_state(self: *Self) !void {
        _ = self;
    }

    pub fn resolve_result_vector(self: *Self) !void {
        _ = self;
    }

};

test "NodeRelEvaluator" {
    const allocator = std.testing.allocator;
    var instance = NodeRelEvaluator.init(allocator);
    defer instance.deinit();
}

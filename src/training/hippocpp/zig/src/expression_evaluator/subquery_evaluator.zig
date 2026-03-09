//! SubqueryEvaluator — graph database engine module.
//!

const std = @import("std");

pub const SubqueryEvaluator = struct {
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

test "SubqueryEvaluator" {
    const allocator = std.testing.allocator;
    var instance = SubqueryEvaluator.init(allocator);
    defer instance.deinit();
}

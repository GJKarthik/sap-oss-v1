//! MapDummySink — graph database engine module.
//!
//! Implements OperatorMapper interface for MapDummySink operations.

const std = @import("std");

pub const MapDummySink = struct {
    allocator: std.mem.Allocator,
    logical_operator: ?*anyopaque = null,
    physical_plan: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Perform map operation.
    pub fn map(self: *Self) !void {
        _ = self;
    }

    pub fn create_result_collector(self: *Self) !void {
        _ = self;
    }

};

test "MapDummySink" {
    const allocator = std.testing.allocator;
    var instance = MapDummySink.init(allocator);
    defer instance.deinit();
}

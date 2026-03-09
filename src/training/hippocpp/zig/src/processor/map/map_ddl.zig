//! MapDdl — graph database engine module.
//!
//! Implements OperatorMapper interface for MapDdl operations.

const std = @import("std");

pub const MapDdl = struct {
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

test "MapDdl" {
    const allocator = std.testing.allocator;
    var instance = MapDdl.init(allocator);
    defer instance.deinit();
}

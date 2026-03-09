//! NodeTableSchema — graph database engine module.
//!

const std = @import("std");

pub const NodeTableSchema = struct {
    allocator: std.mem.Allocator,
    oid: u64 = 0,
    name: []const u8 = "",

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn serialize(self: *Self) !void {
        _ = self;
    }

    pub fn deserialize(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_name(self: *const Self) []const u8 {
        _ = self;
        return "node_table_schema";
    }

};

test "NodeTableSchema" {
    const allocator = std.testing.allocator;
    var instance = NodeTableSchema.init(allocator);
    defer instance.deinit();
    _ = instance.get_name();
}

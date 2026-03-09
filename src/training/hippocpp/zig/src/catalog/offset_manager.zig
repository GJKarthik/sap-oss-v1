//! OffsetManager — graph database engine module.
//!

const std = @import("std");

pub const OffsetManager = struct {
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
        return "offset_manager";
    }

};

test "OffsetManager" {
    const allocator = std.testing.allocator;
    var instance = OffsetManager.init(allocator);
    defer instance.deinit();
    _ = instance.get_name();
}

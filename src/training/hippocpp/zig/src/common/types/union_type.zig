//! UnionType — graph database engine module.
//!

const std = @import("std");

pub const UnionType = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn toString(self: *const Self) []const u8 {
        _ = self;
        return "union_type";
    }

    pub fn fromString(self: *Self) !void {
        _ = self;
    }

    pub fn cast(self: *Self) !void {
        _ = self;
    }

};

test "UnionType" {
    const allocator = std.testing.allocator;
    var instance = UnionType.init(allocator);
    defer instance.deinit();
    _ = instance.toString();
}

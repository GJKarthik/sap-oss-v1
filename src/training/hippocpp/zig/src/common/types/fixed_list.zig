//! FixedList — graph database engine module.
//!

const std = @import("std");

pub const FixedList = struct {
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
        return "fixed_list";
    }

    pub fn fromString(self: *Self) !void {
        _ = self;
    }

    pub fn cast(self: *Self) !void {
        _ = self;
    }

};

test "FixedList" {
    const allocator = std.testing.allocator;
    var instance = FixedList.init(allocator);
    defer instance.deinit();
    _ = instance.toString();
}

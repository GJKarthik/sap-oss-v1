//! Kuzu — graph database engine module.
//!

const std = @import("std");

pub const Kuzu = struct {
    allocator: std.mem.Allocator,
    handle: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn create(self: *Self) !void {
        _ = self;
    }

    pub fn destroy(self: *Self) !void {
        _ = self;
    }

    pub fn get_error(self: *const Self) []const u8 {
        _ = self;
        return "kuzu";
    }

};

test "Kuzu" {
    const allocator = std.testing.allocator;
    var instance = Kuzu.init(allocator);
    defer instance.deinit();
    _ = instance.get_error();
}

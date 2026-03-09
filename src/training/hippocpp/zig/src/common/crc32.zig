//! Crc32 — graph database engine module.
//!

const std = @import("std");

pub const Crc32 = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }



};

test "Crc32" {
    const allocator = std.testing.allocator;
    var instance = Crc32.init(allocator);
    defer instance.deinit();
}

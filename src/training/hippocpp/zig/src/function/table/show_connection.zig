//! ShowConnection — graph database engine module.
//!

const std = @import("std");

pub const ShowConnection = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }



};

test "ShowConnection" {
    const allocator = std.testing.allocator;
    var instance = ShowConnection.init(allocator);
    defer instance.deinit();
}

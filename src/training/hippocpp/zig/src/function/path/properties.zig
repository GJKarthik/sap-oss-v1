//! Properties — graph database engine module.
//!

const std = @import("std");

pub const Properties = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }



};

test "Properties" {
    const allocator = std.testing.allocator;
    var instance = Properties.init(allocator);
    defer instance.deinit();
}

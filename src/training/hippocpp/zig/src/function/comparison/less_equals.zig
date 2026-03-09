//! LessEquals — graph database engine module.
//!

const std = @import("std");

pub const LessEquals = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }



};

test "LessEquals" {
    const allocator = std.testing.allocator;
    var instance = LessEquals.init(allocator);
    defer instance.deinit();
}

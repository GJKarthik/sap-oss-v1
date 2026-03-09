//! Nextval — graph database engine module.
//!

const std = @import("std");

pub const Nextval = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }



};

test "Nextval" {
    const allocator = std.testing.allocator;
    var instance = Nextval.init(allocator);
    defer instance.deinit();
}

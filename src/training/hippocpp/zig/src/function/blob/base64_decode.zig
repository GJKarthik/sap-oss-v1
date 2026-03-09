//! Base64Decode — graph database engine module.
//!

const std = @import("std");

pub const Base64Decode = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }



};

test "Base64Decode" {
    const allocator = std.testing.allocator;
    var instance = Base64Decode.init(allocator);
    defer instance.deinit();
}

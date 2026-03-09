//! Base64Encode — graph database engine module.
//!

const std = @import("std");

pub const Base64Encode = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }



};

test "Base64Encode" {
    const allocator = std.testing.allocator;
    var instance = Base64Encode.init(allocator);
    defer instance.deinit();
}

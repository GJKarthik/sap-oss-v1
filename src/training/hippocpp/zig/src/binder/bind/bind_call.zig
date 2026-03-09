//! BindCall — graph database engine module.
//!

const std = @import("std");

pub const BindCall = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Perform bind_statement operation.
    pub fn bind_statement(self: *Self) !void {
        _ = self;
    }

};

test "BindCall" {
    const allocator = std.testing.allocator;
    var instance = BindCall.init(allocator);
    defer instance.deinit();
}

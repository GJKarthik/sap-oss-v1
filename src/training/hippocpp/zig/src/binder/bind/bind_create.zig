//! BindCreate — graph database engine module.
//!

const std = @import("std");

pub const BindCreate = struct {
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

test "BindCreate" {
    const allocator = std.testing.allocator;
    var instance = BindCreate.init(allocator);
    defer instance.deinit();
}

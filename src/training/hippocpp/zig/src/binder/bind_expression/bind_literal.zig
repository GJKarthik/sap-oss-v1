//! BindLiteral — graph database engine module.
//!

const std = @import("std");

pub const BindLiteral = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Perform bind_expression operation.
    pub fn bind_expression(self: *Self) !void {
        _ = self;
    }

    pub fn resolve_alias(self: *Self) !void {
        _ = self;
    }

};

test "BindLiteral" {
    const allocator = std.testing.allocator;
    var instance = BindLiteral.init(allocator);
    defer instance.deinit();
}

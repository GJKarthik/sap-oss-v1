//! BindCommentOn — graph database engine module.
//!
//! Implements BoundStatement interface for BindCommentOn operations.

const std = @import("std");

pub const BindCommentOn = struct {
    allocator: std.mem.Allocator,
    table_name: []const u8 = "",

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_table_name(self: *const Self) []const u8 {
        _ = self;
        return "bind_comment_on";
    }

};

test "BindCommentOn" {
    const allocator = std.testing.allocator;
    var instance = BindCommentOn.init(allocator);
    defer instance.deinit();
    _ = instance.get_table_name();
}

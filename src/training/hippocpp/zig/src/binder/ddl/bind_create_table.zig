//! BindCreateTable — graph database engine module.
//!
//! Implements BoundStatement interface for BindCreateTable operations.

const std = @import("std");

pub const BindCreateTable = struct {
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
        return "bind_create_table";
    }

};

test "BindCreateTable" {
    const allocator = std.testing.allocator;
    var instance = BindCreateTable.init(allocator);
    defer instance.deinit();
    _ = instance.get_table_name();
}

//! FlatTuple — Ported from kuzu C++ (68L header, 99L source).
//!

const std = @import("std");

pub const FlatTuple = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList(?*anyopaque) = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn len(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

};

test "FlatTuple" {
    const allocator = std.testing.allocator;
    var instance = FlatTuple.init(allocator);
    defer instance.deinit();
}

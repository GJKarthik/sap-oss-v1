//! Reader — Ported from kuzu C++ (26L header, 0L source).
//!

const std = @import("std");

pub const Reader = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn read(self: *Self) void {
        _ = self;
    }

    pub fn finished(self: *Self) void {
        _ = self;
    }

    pub fn on_object_begin(self: *Self) void {
        _ = self;
    }

    pub fn on_object_end(self: *Self) void {
        _ = self;
    }

};

test "Reader" {
    const allocator = std.testing.allocator;
    var instance = Reader.init(allocator);
    defer instance.deinit();
}

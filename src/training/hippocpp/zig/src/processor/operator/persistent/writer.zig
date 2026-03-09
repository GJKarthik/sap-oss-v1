//! Writer — Ported from kuzu C++ (32L header, 0L source).
//!

const std = @import("std");

pub const Writer = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn write(self: *Self) void {
        _ = self;
    }

    pub fn get_size(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn clear(self: *Self) void {
        _ = self;
    }

    pub fn flush(self: *Self) void {
        _ = self;
    }

    pub fn sync(self: *Self) void {
        _ = self;
    }

    pub fn on_object_begin(self: *Self) void {
        _ = self;
    }

    pub fn on_object_end(self: *Self) void {
        _ = self;
    }

};

test "Writer" {
    const allocator = std.testing.allocator;
    var instance = Writer.init(allocator);
    defer instance.deinit();
    _ = instance.get_size();
}

//! FrontierMorsel — Ported from kuzu C++ (49L header, 0L source).
//!

const std = @import("std");

pub const FrontierMorsel = struct {
    allocator: std.mem.Allocator,
    beginOffset: ?*anyopaque = null,
    endOffset: ?*anyopaque = null,
    maxOffset: u64 = 0,
    nextOffset: ?*anyopaque = null,
    maxThreads: u64 = 0,
    morselSize: u64 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_begin_offset(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_end_offset(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn frontier_morsel_dispatcher(self: *Self) void {
        _ = self;
    }

    pub fn get_next_range_morsel(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

};

test "FrontierMorsel" {
    const allocator = std.testing.allocator;
    var instance = FrontierMorsel.init(allocator);
    defer instance.deinit();
    _ = instance.get_begin_offset();
    _ = instance.get_end_offset();
}

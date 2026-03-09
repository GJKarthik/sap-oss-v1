//! SequenceVector — graph database engine module.
//!

const std = @import("std");

pub const SequenceVector = struct {
    allocator: std.mem.Allocator,
    data: ?[*]u8 = null,
    size: u64 = 0,
    capacity: u64 = 0,
    null_mask: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_value(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn set_value(self: *Self) !void {
        _ = self;
    }

    pub fn reset(self: *Self) !void {
        _ = self;
    }

    pub fn resize(self: *Self) !void {
        _ = self;
    }

};

test "SequenceVector" {
    const allocator = std.testing.allocator;
    var instance = SequenceVector.init(allocator);
    defer instance.deinit();
}

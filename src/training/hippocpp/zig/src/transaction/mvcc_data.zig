//! MvccData — graph database engine module.
//!

const std = @import("std");

pub const MvccData = struct {
    allocator: std.mem.Allocator,
    transaction_id: u64 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn begin(self: *Self) !void {
        _ = self;
    }

    pub fn commit(self: *Self) !void {
        _ = self;
    }

    pub fn rollback(self: *Self) !void {
        _ = self;
    }

};

test "MvccData" {
    const allocator = std.testing.allocator;
    var instance = MvccData.init(allocator);
    defer instance.deinit();
}

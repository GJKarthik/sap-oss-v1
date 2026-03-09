//! ChunkedNodeGroup — Ported from kuzu C++ (29L header, 0L source).
//!

const std = @import("std");

pub const ChunkedNodeGroup = struct {
    allocator: std.mem.Allocator,
    ChunkedNodeGroup: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn apply_func_to_chunked_groups(self: *Self) void {
        _ = self;
    }

    pub fn rollback_insert(self: *Self) void {
        _ = self;
    }

};

test "ChunkedNodeGroup" {
    const allocator = std.testing.allocator;
    var instance = ChunkedNodeGroup.init(allocator);
    defer instance.deinit();
}

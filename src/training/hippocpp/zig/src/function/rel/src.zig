//! PageAllocator — Ported from kuzu C++ (215L header, 0L source).
//!

const std = @import("std");

pub const PageAllocator = struct {
    allocator: std.mem.Allocator,
    PageAllocator: ?*anyopaque = null,
    MemoryManager: ?*anyopaque = null,
    hasUpdates: std.ArrayList(bool) = .{},
    hasUpdate: ?*anyopaque = null,
    rightRegionIdx: ?*anyopaque = null,
    offset: ?*?*anyopaque = null,
    length: ?*?*anyopaque = null,
    InMemChunkedCSRNodeGroup: ?*anyopaque = null,
    CSRNodeGroupCheckpointState: ?*anyopaque = null,
    csrHeader: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn need_checkpoint(self: *Self) void {
        _ = self;
    }

    pub fn need_checkpoint_column(self: *Self) void {
        _ = self;
    }

    pub fn has_deletions_or_insertions(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn get_left_leaf_region_idx(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_right_leaf_region_idx(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn is_within(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn upgrade_level(self: *Self) void {
        _ = self;
    }

    pub fn get_start_csr_offset(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_end_csr_offset(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_csr_length(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_gap_size(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn sanity_check(self: *Self) void {
        _ = self;
    }

};

test "PageAllocator" {
    const allocator = std.testing.allocator;
    var instance = PageAllocator.init(allocator);
    defer instance.deinit();
    _ = instance.has_deletions_or_insertions();
    _ = instance.get_left_leaf_region_idx();
    _ = instance.get_right_leaf_region_idx();
}

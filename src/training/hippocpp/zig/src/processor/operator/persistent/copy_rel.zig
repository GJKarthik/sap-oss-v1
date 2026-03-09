//! CSRNodeGroup — Ported from kuzu C++ (48L header, 0L source).
//!

const std = @import("std");

pub const CSRNodeGroup = struct {
    allocator: std.mem.Allocator,
    CSRNodeGroup: ?*anyopaque = null,
    InMemChunkedCSRHeader: ?*anyopaque = null,
    partitioningBuffer: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn populate_csr_lengths(self: *Self) void {
        _ = self;
    }

    pub fn finalize_start_csr_offsets(self: *Self) void {
        _ = self;
    }

    pub fn write_to_table(self: *Self) void {
        _ = self;
    }

    pub fn set_row_idx_from_csr_offsets(self: *Self) void {
        _ = self;
    }

    pub fn populate_csr_lengths_internal(self: *Self) void {
        _ = self;
    }

};

test "CSRNodeGroup" {
    const allocator = std.testing.allocator;
    var instance = CSRNodeGroup.init(allocator);
    defer instance.deinit();
}

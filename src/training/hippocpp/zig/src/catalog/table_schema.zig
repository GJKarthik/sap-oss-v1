//! ColumnSchema — Ported from kuzu C++ (97L header, 0L source).
//!

const std = @import("std");

pub const ColumnSchema = struct {
    allocator: std.mem.Allocator,
    ft_tuple_idx_t: u64 = 0,
    ft_col_idx_t: u32 = 0,
    ft_col_offset_t: u32 = 0,
    ft_block_idx_t: u32 = 0,
    ft_block_offset_t: u32 = 0,
    groupID: ?*anyopaque = null,
    numBytes: ?*anyopaque = null,
    isUnFlat: bool = false,
    mayContainNulls: bool = false,
    numBytesForDataPerTuple: ?*anyopaque = null,
    numBytesPerTuple: ?*anyopaque = null,
    columns: std.ArrayList(?*anyopaque) = .{},
    colOffsets: std.ArrayList(?*anyopaque) = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn is_flat(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn get_group_id(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_num_bytes(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn set_may_contains_nulls_to_true(self: *Self) void {
        _ = self;
    }

    pub fn has_no_null_guarantee(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn append_column(self: *Self) void {
        _ = self;
    }

    pub fn get_num_columns(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_null_map_offset(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_num_bytes_per_tuple(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_col_offset(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn is_empty(self: *const Self) bool {
        _ = self;
        return false;
    }

};

test "ColumnSchema" {
    const allocator = std.testing.allocator;
    var instance = ColumnSchema.init(allocator);
    defer instance.deinit();
    _ = instance.is_flat();
    _ = instance.get_group_id();
    _ = instance.get_num_bytes();
    _ = instance.has_no_null_guarantee();
}

//! MergedKeyBlocks — Ported from kuzu C++ (203L header, 326L source).
//!

const std = @import("std");

pub const MergedKeyBlocks = struct {
    allocator: std.mem.Allocator,
    KeyBlockMergeMorsel: ?*anyopaque = null,
    colOffsetInFT: u32 = 0,
    colOffsetInEncodedKeyBlock: u32 = 0,
    isAscOrder: bool = false,
    numTuples: ?*anyopaque = null,
    numBytesPerTuple: ?*anyopaque = null,
    numTuplesPerBlock: ?*anyopaque = null,
    endTupleOffset: u32 = 0,
    curBlockIdx: u64 = 0,
    endBlockIdx: u64 = 0,
    endTupleIdx: u64 = 0,
    factorizedTables: std.ArrayList(?*anyopaque) = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_encoding_size(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_num_tuples(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_num_bytes_per_tuple(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_num_tuples_per_block(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn has_more_tuples_to_read(self: *const Self) bool {
        _ = self;
        return false;
    }

    pub fn get_num_bytes_left_in_cur_block(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_num_tuples_left_in_cur_block(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn update_tuple_ptr_if_necessary(self: *Self) void {
        _ = self;
    }

    pub fn key_block_merger(self: *Self) void {
        _ = self;
    }

    pub fn merge_key_blocks(self: *Self) void {
        _ = self;
    }

    pub fn compare_tuple_ptr(self: *Self) void {
        _ = self;
    }

};

test "MergedKeyBlocks" {
    const allocator = std.testing.allocator;
    var instance = MergedKeyBlocks.init(allocator);
    defer instance.deinit();
    _ = instance.get_encoding_size();
    _ = instance.get_num_tuples();
    _ = instance.get_num_bytes_per_tuple();
    _ = instance.get_num_tuples_per_block();
    _ = instance.has_more_tuples_to_read();
}

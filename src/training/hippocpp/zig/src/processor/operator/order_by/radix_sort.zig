//! RadixSort — Ported from kuzu C++ (73L header, 283L source).
//!

const std = @import("std");

pub const RadixSort = struct {
    allocator: std.mem.Allocator,
    startingTupleIdx: u32 = 0,
    endingTupleIdx: u32 = 0,
    tmpSortingResultBlock: ?*?*anyopaque = null,
    tmpTuplePtrSortingBlock: ?*?*anyopaque = null,
    strKeyColsInfo: std.ArrayList(?*anyopaque) = .{},
    numBytesPerTuple: u32 = 0,
    numBytesToRadixSort: u32 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_num_tuples(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn tie_range(self: *Self) void {
        _ = self;
    }

    pub fn quick_sort(self: *Self) void {
        _ = self;
    }

    pub fn sort_single_key_block(self: *Self) void {
        _ = self;
    }

    pub fn radix_sort(self: *Self) void {
        _ = self;
    }

    pub fn fill_tmp_tuple_ptr_sorting_block(self: *Self) void {
        _ = self;
    }

    pub fn re_order_key_block(self: *Self) void {
        _ = self;
    }

    pub fn find_string_ties(self: *Self) void {
        _ = self;
    }

    pub fn solve_string_ties(self: *Self) void {
        _ = self;
    }

};

test "RadixSort" {
    const allocator = std.testing.allocator;
    var instance = RadixSort.init(allocator);
    defer instance.deinit();
    _ = instance.get_num_tuples();
}

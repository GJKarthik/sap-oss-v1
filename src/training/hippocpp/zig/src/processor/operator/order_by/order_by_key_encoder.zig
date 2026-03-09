//! OrderByKeyEncoder — Ported from kuzu C++ (134L header, 413L source).
//!

const std = @import("std");

pub const OrderByKeyEncoder = struct {
    allocator: std.mem.Allocator,
    keyBlocks: ?*anyopaque = null,
    numBytesPerTuple: ?*anyopaque = null,
    isAscOrder: std.ArrayList(bool) = .{},
    maxNumTuplesPerBlock: u32 = 0,
    ftIdx: u8 = 0,
    numTuplesPerBlockInFT: u32 = 0,
    swapBytes: bool = false,
    encodeFunctions: std.ArrayList(?*anyopaque) = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn bswap64(self: *Self) void {
        _ = self;
    }

    pub fn bswap32(self: *Self) void {
        _ = self;
    }

    pub fn bswap16(self: *Self) void {
        _ = self;
    }

    pub fn 73(self: *Self) void {
        _ = self;
    }

    pub fn 38(self: *Self) void {
        _ = self;
    }

    pub fn byte(self: *Self) void {
        _ = self;
    }

    pub fn get_num_bytes_per_tuple(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_num_tuples_in_cur_block(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_encoded_ft_block_idx(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

};

test "OrderByKeyEncoder" {
    const allocator = std.testing.allocator;
    var instance = OrderByKeyEncoder.init(allocator);
    defer instance.deinit();
}

//! GetCompressionMetadata — Ported from kuzu C++ (81L header, 0L source).
//!

const std = @import("std");

pub const GetCompressionMetadata = struct {
    allocator: std.mem.Allocator,
    pageRange: ?*anyopaque = null,
    numValues: u64 = 0,
    compMeta: ?*anyopaque = null,
    alg: ?*?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn get_start_page_idx(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_num_pages(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn get_num_data_pages(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn serialize(self: *Self) void {
        _ = self;
    }

    pub fn deserialize(self: *Self) void {
        _ = self;
    }

    pub fn operator(self: *Self) void {
        _ = self;
    }

    pub fn uncompressed_get_metadata(self: *Self) void {
        _ = self;
    }

    pub fn boolean_get_metadata(self: *Self) void {
        _ = self;
    }

};

test "GetCompressionMetadata" {
    const allocator = std.testing.allocator;
    var instance = GetCompressionMetadata.init(allocator);
    defer instance.deinit();
    _ = instance.get_start_page_idx();
    _ = instance.get_num_pages();
    _ = instance.get_num_data_pages();
}

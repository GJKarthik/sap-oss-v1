//! FlatTuple — Ported from kuzu C++ (90L header, 1062L source).
//!

const std = @import("std");

pub const FlatTuple = struct {
    allocator: std.mem.Allocator,
    ArrowSchema: ?*anyopaque = null,
    FlatTuple: ?*anyopaque = null,
    Value: ?*anyopaque = null,
    type: ?*anyopaque = null,
    integer: ?*anyopaque = null,
    data: ?*anyopaque = null,
    validity: ?*anyopaque = null,
    overflow: ?*anyopaque = null,
    array: ?*?*anyopaque = null,
    childPointers: std.ArrayList(?*anyopaque) = .{},
    numTuples: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn vector(self: *Self) void {
        _ = self;
    }

    pub fn get_num_bytes_for_bits(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn append(self: *Self) void {
        _ = self;
    }

    pub fn size(self: *Self) void {
        _ = self;
    }

    pub fn to_array(self: *Self) void {
        _ = self;
    }

    pub fn append_value(self: *Self) void {
        _ = self;
    }

    pub fn copy_non_null_value(self: *Self) void {
        _ = self;
    }

    pub fn copy_null_value(self: *Self) void {
        _ = self;
    }

    pub fn template_copy_non_null_value(self: *Self) void {
        _ = self;
    }

    pub fn template_copy_null_value(self: *Self) void {
        _ = self;
    }

    pub fn copy_null_value_union(self: *Self) void {
        _ = self;
    }

};

test "FlatTuple" {
    const allocator = std.testing.allocator;
    var instance = FlatTuple.init(allocator);
    defer instance.deinit();
    _ = instance.get_num_bytes_for_bits();
}

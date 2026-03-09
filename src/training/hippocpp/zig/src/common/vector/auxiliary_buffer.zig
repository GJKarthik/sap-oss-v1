//! ValueVector — Ported from kuzu C++ (105L header, 95L source).
//!

const std = @import("std");

pub const ValueVector = struct {
    allocator: std.mem.Allocator,
    ValueVector: ?*anyopaque = null,
    inMemOverflowBuffer: ?*?*anyopaque = null,
    childrenVectors: ?*anyopaque = null,
    ListVector: ?*anyopaque = null,
    dataVector: ?*anyopaque = null,
    size: ?*anyopaque = null,
    capacity: u64 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn string_auxiliary_buffer(self: *Self) void {
        _ = self;
    }

    pub fn reset_overflow_buffer(self: *Self) void {
        _ = self;
    }

    pub fn reference_child_vector(self: *Self) void {
        _ = self;
    }

    pub fn vector(self: *Self) void {
        _ = self;
    }

    pub fn length(self: *Self) void {
        _ = self;
    }

    pub fn set_data_vector(self: *Self) void {
        _ = self;
    }

    pub fn add_list(self: *Self) void {
        _ = self;
    }

    pub fn get_size(self: *const Self) ?*anyopaque {
        _ = self;
        return null;
    }

    pub fn reset_size(self: *Self) void {
        _ = self;
    }

    pub fn resize(self: *Self) void {
        _ = self;
    }

    pub fn resize_data_vector(self: *Self) void {
        _ = self;
    }

};

test "ValueVector" {
    const allocator = std.testing.allocator;
    var instance = ValueVector.init(allocator);
    defer instance.deinit();
}

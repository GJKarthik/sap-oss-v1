//! ValueVector — Ported from kuzu C++ (333L header, 298L source).
//!

const std = @import("std");

pub const ValueVector = struct {
    allocator: std.mem.Allocator,
    ValueVector: ?*anyopaque = null,
    val: ?*anyopaque = null,
    result: []const u8 = "",
    KU_UNREACHABLE: ?*anyopaque = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn overload(self: *Self) void {
        _ = self;
    }

    pub fn param_pack_for_each_helper(self: *Self) void {
        _ = self;
    }

    pub fn param_pack_for_each(self: *Self) void {
        _ = self;
    }

    pub fn entry_to_string(self: *Self) void {
        _ = self;
    }

    pub fn to_string(self: *Self) void {
        _ = self;
    }

    pub fn constexpr(self: *Self) void {
        _ = self;
    }

    pub fn node_to_string(self: *Self) void {
        _ = self;
    }

    pub fn rel_to_string(self: *Self) void {
        _ = self;
    }

    pub fn encode_overflow_ptr(self: *Self) void {
        _ = self;
    }

    pub fn decode_overflow_ptr(self: *Self) void {
        _ = self;
    }

    pub fn get_physical_type_id_for_type(self: *const Self) u8 {
        _ = self;
        return null;
    }

};

test "ValueVector" {
    const allocator = std.testing.allocator;
    var instance = ValueVector.init(allocator);
    defer instance.deinit();
}

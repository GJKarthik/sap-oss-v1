//! Kuzu List Type — variable-length list with offset/size.
//!
//! Ported from kuzu/src/common/types/ku_list.h.

const std = @import("std");

/// List entry pointing into a data vector.
pub const ku_list_t = struct {
    offset: u64 = 0,
    size: u64 = 0,

    const Self = @This();

    pub fn init(off: u64, sz: u64) Self {
        return .{ .offset = off, .size = sz };
    }
    pub fn empty() Self { return .{}; }

    pub fn eql(self: Self, other: Self) bool {
        return self.offset == other.offset and self.size == other.size;
    }
};

/// Overflow value for nested data (variable-length).
pub const overflow_value_t = struct {
    num_elements: u64 = 0,
    value: ?[*]u8 = null,
};

test "ku_list_t basic" {
    const list = ku_list_t.init(10, 5);
    try std.testing.expectEqual(@as(u64, 10), list.offset);
    try std.testing.expectEqual(@as(u64, 5), list.size);
    try std.testing.expect(list.eql(ku_list_t.init(10, 5)));
    try std.testing.expect(!list.eql(ku_list_t.init(10, 6)));
}

test "ku_list_t empty" {
    const empty = ku_list_t.empty();
    try std.testing.expectEqual(@as(u64, 0), empty.offset);
    try std.testing.expectEqual(@as(u64, 0), empty.size);
}

//! Internal ID Type — (offset, tableID) pair for node/rel identification.
//!
//! Ported from kuzu/src/common/types/internal_id_t.h.

const std = @import("std");

pub const offset_t = u64;
pub const table_id_t = u64;
pub const INVALID_OFFSET: offset_t = std.math.maxInt(u64);
pub const INVALID_TABLE_ID: table_id_t = std.math.maxInt(u64);

pub const internalID_t = struct {
    offset: offset_t,
    tableID: table_id_t,

    const Self = @This();

    pub fn init(off: offset_t, tid: table_id_t) Self {
        return .{ .offset = off, .tableID = tid };
    }

    pub fn invalid() Self {
        return .{ .offset = INVALID_OFFSET, .tableID = INVALID_TABLE_ID };
    }

    pub fn isValid(self: Self) bool {
        return self.offset != INVALID_OFFSET and self.tableID != INVALID_TABLE_ID;
    }

    pub fn eql(self: Self, other: Self) bool {
        return self.offset == other.offset and self.tableID == other.tableID;
    }

    pub fn lessThan(self: Self, other: Self) bool {
        if (self.tableID < other.tableID) return true;
        if (self.tableID > other.tableID) return false;
        return self.offset < other.offset;
    }

    pub fn greaterThan(self: Self, other: Self) bool {
        return other.lessThan(self);
    }

    pub fn hash(self: Self) u64 {
        return self.offset ^ (self.tableID *% 0x9e3779b97f4a7c15);
    }
};

pub const nodeID_t = internalID_t;
pub const relID_t = internalID_t;

test "internalID_t basic" {
    const id1 = internalID_t.init(10, 1);
    const id2 = internalID_t.init(20, 1);
    const id3 = internalID_t.init(10, 2);

    try std.testing.expect(id1.eql(id1));
    try std.testing.expect(!id1.eql(id2));
    try std.testing.expect(id1.lessThan(id2));
    try std.testing.expect(id1.lessThan(id3));
    try std.testing.expect(id2.greaterThan(id1));
}

test "internalID_t invalid" {
    const inv = internalID_t.invalid();
    try std.testing.expect(!inv.isValid());
    try std.testing.expect(inv.offset == INVALID_OFFSET);
    try std.testing.expect(inv.tableID == INVALID_TABLE_ID);
}

test "internalID_t hash" {
    const id1 = internalID_t.init(10, 1);
    const id2 = internalID_t.init(10, 1);
    try std.testing.expectEqual(id1.hash(), id2.hash());
}

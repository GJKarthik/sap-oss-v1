//! Primary-key scan helper for node tables.

const std = @import("std");

pub const NodeIndexEntry = struct {
    primary_key: []const u8,
    offset: u64,
};

pub fn findOffset(entries: []const NodeIndexEntry, key: []const u8) ?u64 {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.primary_key, key)) return entry.offset;
    }
    return null;
}

test "primary key scan" {
    const entries = [_]NodeIndexEntry{
        .{ .primary_key = "a", .offset = 1 },
        .{ .primary_key = "b", .offset = 2 },
    };
    try std.testing.expectEqual(@as(u64, 2), findOffset(&entries, "b").?);
}

//! Hash aggregate scan helpers.

const std = @import("std");
const base = @import("base_aggregate.zig");

pub const HashAggregateEntry = struct {
    group_key: []const u8,
    state: base.AggregateState,
};

pub fn findByGroup(entries: []const HashAggregateEntry, group_key: []const u8) ?base.AggregateState {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.group_key, group_key)) {
            return entry.state;
        }
    }
    return null;
}

test "find hash aggregate group" {
    var s = base.AggregateState{};
    s.update(4);
    const entries = [_]HashAggregateEntry{ .{ .group_key = "g1", .state = s } };
    const got = findByGroup(&entries, "g1");
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(i64, 4), got.?.finalize(.sum).?);
}

//! Simple aggregate scan over a single value stream.

const std = @import("std");
const base = @import("base_aggregate.zig");

pub fn aggregate(values: []const ?i64, kind: base.AggregationKind) ?i64 {
    var state = base.AggregateState{};
    for (values) |v| state.update(v);
    return state.finalize(kind);
}

test "simple aggregate scan" {
    const vals = [_]?i64{ 1, 2, 3, null };
    try std.testing.expectEqual(@as(i64, 6), aggregate(&vals, .sum).?);
}

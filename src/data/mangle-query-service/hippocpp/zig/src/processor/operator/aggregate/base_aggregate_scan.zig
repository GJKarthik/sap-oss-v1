//! Scan helper for aggregate states.

const std = @import("std");
const base = @import("base_aggregate.zig");

pub fn scanAggregates(states: []const base.AggregateState, kind: base.AggregationKind, out: []?i64) !void {
    if (out.len < states.len) return error.OutputTooSmall;
    for (states, 0..) |state, idx| {
        out[idx] = state.finalize(kind);
    }
}

test "scan aggregates" {
    var states = [_]base.AggregateState{ .{}, .{} };
    states[0].update(1);
    states[0].update(2);
    states[1].update(7);

    var out = [_]?i64{ null, null };
    try scanAggregates(&states, .sum, &out);
    try std.testing.expectEqual(@as(i64, 3), out[0].?);
    try std.testing.expectEqual(@as(i64, 7), out[1].?);
}

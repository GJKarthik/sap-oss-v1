//! Base aggregate state and update logic.

const std = @import("std");

pub const AggregationKind = enum {
    count,
    sum,
    min,
    max,
};

pub const AggregateState = struct {
    count: u64 = 0,
    sum: i64 = 0,
    min: ?i64 = null,
    max: ?i64 = null,

    pub fn update(self: *AggregateState, value: ?i64) void {
        self.count += 1;
        if (value) |v| {
            self.sum += v;
            if (self.min == null or v < self.min.?) self.min = v;
            if (self.max == null or v > self.max.?) self.max = v;
        }
    }

    pub fn finalize(self: *const AggregateState, kind: AggregationKind) ?i64 {
        return switch (kind) {
            .count => @as(i64, @intCast(self.count)),
            .sum => self.sum,
            .min => self.min,
            .max => self.max,
        };
    }
};

test "aggregate state update and finalize" {
    var state = AggregateState{};
    state.update(5);
    state.update(3);
    state.update(null);

    try std.testing.expectEqual(@as(i64, 3), state.finalize(.count).?);
    try std.testing.expectEqual(@as(i64, 8), state.finalize(.sum).?);
    try std.testing.expectEqual(@as(i64, 3), state.finalize(.min).?);
    try std.testing.expectEqual(@as(i64, 5), state.finalize(.max).?);
}

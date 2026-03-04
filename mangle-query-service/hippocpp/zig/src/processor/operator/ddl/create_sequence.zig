//! CREATE SEQUENCE helpers.

const std = @import("std");

pub const SequenceState = struct {
    next_value: i64,
    increment: i64,

    pub fn init(start: i64, increment: i64) SequenceState {
        return .{ .next_value = start, .increment = increment };
    }

    pub fn next(self: *SequenceState) i64 {
        const current = self.next_value;
        self.next_value += self.increment;
        return current;
    }
};

test "sequence next values" {
    var seq = SequenceState.init(10, 2);
    try std.testing.expectEqual(@as(i64, 10), seq.next());
    try std.testing.expectEqual(@as(i64, 12), seq.next());
}

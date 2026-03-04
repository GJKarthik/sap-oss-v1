//! Sink operator state.

const std = @import("std");

pub const SinkState = struct {
    rows: u64 = 0,

    pub fn push(self: *SinkState, count: u64) void {
        self.rows += count;
    }
};

test "sink push" {
    var sink = SinkState{};
    sink.push(5);
    sink.push(2);
    try std.testing.expectEqual(@as(u64, 7), sink.rows);
}

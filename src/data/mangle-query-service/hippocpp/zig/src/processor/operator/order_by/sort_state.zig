//! Runtime state for ORDER BY pipelines.

const std = @import("std");

pub const SortState = struct {
    total_rows: u64 = 0,
    rows_emitted: u64 = 0,
    is_finalized: bool = false,

    pub fn markInputRows(self: *SortState, count: u64) void {
        self.total_rows += count;
    }

    pub fn markOutputRows(self: *SortState, count: u64) void {
        self.rows_emitted += count;
        if (self.rows_emitted >= self.total_rows) {
            self.is_finalized = true;
        }
    }

    pub fn remaining(self: *const SortState) u64 {
        return self.total_rows -| self.rows_emitted;
    }
};

test "sort state accounting" {
    var state = SortState{};
    state.markInputRows(10);
    state.markOutputRows(4);
    try std.testing.expectEqual(@as(u64, 6), state.remaining());
}

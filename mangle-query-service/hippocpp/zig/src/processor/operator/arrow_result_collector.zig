//! Arrow-style result collector metadata.

const std = @import("std");

pub const ArrowResultSummary = struct {
    column_count: usize,
    row_count: usize,
};

pub fn summarize(column_count: usize, row_count: usize) ArrowResultSummary {
    return .{ .column_count = column_count, .row_count = row_count };
}

test "arrow result summary" {
    const summary = summarize(3, 12);
    try std.testing.expectEqual(@as(usize, 3), summary.column_count);
    try std.testing.expectEqual(@as(usize, 12), summary.row_count);
}

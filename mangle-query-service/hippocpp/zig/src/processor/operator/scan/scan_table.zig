//! Generic table scan cursor.

const std = @import("std");

pub const TableScanCursor = struct {
    total_rows: u64,
    current: u64 = 0,

    pub fn init(total_rows: u64) TableScanCursor {
        return .{ .total_rows = total_rows };
    }

    pub fn hasNext(self: *const TableScanCursor) bool {
        return self.current < self.total_rows;
    }

    pub fn next(self: *TableScanCursor) ?u64 {
        if (!self.hasNext()) return null;
        const idx = self.current;
        self.current += 1;
        return idx;
    }
};

test "table scan cursor" {
    var cursor = TableScanCursor.init(2);
    try std.testing.expectEqual(@as(u64, 0), cursor.next().?);
    try std.testing.expectEqual(@as(u64, 1), cursor.next().?);
    try std.testing.expect(cursor.next() == null);
}

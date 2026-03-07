//! ORDER BY scan over sorted row ids.

const std = @import("std");

pub const OrderByScanner = struct {
    sorted_row_ids: []const usize,
    cursor: usize = 0,

    pub fn init(sorted_row_ids: []const usize) OrderByScanner {
        return .{ .sorted_row_ids = sorted_row_ids };
    }

    pub fn hasNext(self: *const OrderByScanner) bool {
        return self.cursor < self.sorted_row_ids.len;
    }

    pub fn next(self: *OrderByScanner) ?usize {
        if (!self.hasNext()) return null;
        const id = self.sorted_row_ids[self.cursor];
        self.cursor += 1;
        return id;
    }
};

test "order by scanner" {
    const ids = [_]usize{ 3, 1, 2 };
    var scanner = OrderByScanner.init(&ids);
    try std.testing.expectEqual(@as(usize, 3), scanner.next().?);
    try std.testing.expectEqual(@as(usize, 1), scanner.next().?);
}

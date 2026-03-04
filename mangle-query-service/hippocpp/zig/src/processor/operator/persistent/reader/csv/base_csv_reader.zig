//! Base CSV parsing functions.

const std = @import("std");

pub fn splitCsvLine(allocator: std.mem.Allocator, line: []const u8, delimiter: u8) ![][]u8 {
    var fields = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (fields.items) |f| allocator.free(f);
        fields.deinit();
    }

    var it = std.mem.splitScalar(u8, line, delimiter);
    while (it.next()) |part| {
        try fields.append(try allocator.dupe(u8, part));
    }

    return fields.toOwnedSlice();
}

pub fn freeSplit(allocator: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

test "split csv line" {
    const allocator = std.testing.allocator;
    const parts = try splitCsvLine(allocator, "a,b,c", ',');
    defer freeSplit(allocator, parts);
    try std.testing.expectEqual(@as(usize, 3), parts.len);
}

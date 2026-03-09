//! Serial CSV reader.

const std = @import("std");
const base = @import("base_csv_reader.zig");

pub fn readAllLines(allocator: std.mem.Allocator, text: []const u8, delimiter: u8) ![][][]u8 {
    var out = .{};
    errdefer {
        for (out.items) |row| base.freeSplit(allocator, row);
        out.deinit();
    }

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try out.append(allocator, try base.splitCsvLine(allocator, std.mem.trimRight(u8, line, "\r");
    }

    return out.toOwnedSlice();
}

pub fn freeRows(allocator: std.mem.Allocator, rows: [][][]u8) void {
    for (rows) |row| base.freeSplit(allocator, row);
    allocator.free(rows);
}

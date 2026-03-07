//! CSV reader driver entrypoint.

const std = @import("std");
const detect = @import("dialect_detection.zig");
const serial = @import("serial_csv_reader.zig");

pub const CsvReadResult = struct {
    delimiter: u8,
    row_count: usize,
};

pub fn read(allocator: std.mem.Allocator, text: []const u8) !CsvReadResult {
    const dialect = detect.detect(text);
    const rows = try serial.readAllLines(allocator, text, dialect.delimiter);
    defer serial.freeRows(allocator, rows);

    return .{
        .delimiter = dialect.delimiter,
        .row_count = rows.len,
    };
}

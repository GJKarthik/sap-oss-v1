//! Parquet reader orchestrator.

const std = @import("std");
const column = @import("column_reader.zig");

pub const ParquetReader = struct {
    allocator: std.mem.Allocator,
    columns: std.ArrayList(column.ColumnChunk),

    pub fn init(allocator: std.mem.Allocator) ParquetReader {
        return .{ .allocator = allocator, .columns = .{} };
    }

    pub fn deinit(self: *ParquetReader) void {
        self.columns.deinit(self.allocator);
    }

    pub fn addColumn(self: *ParquetReader, name: []const u8, value_count: u64) !void {
        try self.columns.append(self.allocator, .{ .name = name, .value_count = value_count });
    }

    pub fn totalValues(self: *const ParquetReader) u64 {
        var total: u64 = 0;
        for (self.columns.items) |c| total += c.value_count;
        return total;
    }
};

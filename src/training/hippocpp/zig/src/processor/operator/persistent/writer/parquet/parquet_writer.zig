//! Parquet writer orchestration.

const std = @import("std");
const base = @import("column_writer.zig");

pub const ParquetWriter = struct {
    allocator: std.mem.Allocator,
    columns: std.ArrayList(base.ColumnWriter),
    row_groups_written: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) ParquetWriter {
        return .{ .allocator = allocator, .columns = .{} };
    }

    pub fn deinit(self: *ParquetWriter) void {
        self.columns.deinit(self.allocator);
    }

    pub fn addColumn(self: *ParquetWriter, name: []const u8) !void {
        try self.columns.append(self.allocator, base.ColumnWriter.init(name);
    }

    pub fn markRowGroup(self: *ParquetWriter) void {
        self.row_groups_written += 1;
    }
};

test "parquet writer basic" {
    const allocator = std.testing.allocator;
    var writer = ParquetWriter.init(allocator);
    defer writer.deinit(std.testing.allocator);

    try writer.addColumn("id");
    writer.markRowGroup();

    try std.testing.expectEqual(@as(usize, 1), writer.columns.items.len);
    try std.testing.expectEqual(@as(u32, 1), writer.row_groups_written);
}

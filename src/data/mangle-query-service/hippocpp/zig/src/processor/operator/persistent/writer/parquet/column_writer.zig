//! Base Parquet column writer.

const std = @import("std");

pub const ColumnWriter = struct {
    name: []const u8,
    values_written: u64 = 0,

    pub fn init(name: []const u8) ColumnWriter {
        return .{ .name = name };
    }

    pub fn record(self: *ColumnWriter, count: u64) void {
        self.values_written += count;
    }
};

//! Shared types for persistent operators.

const std = @import("std");

pub const ImportStats = struct {
    rows_read: u64 = 0,
    rows_written: u64 = 0,
    rows_failed: u64 = 0,

    pub fn successRate(self: *const ImportStats) f64 {
        const total = self.rows_written + self.rows_failed;
        if (total == 0) return 1.0;
        return @as(f64, @floatFromInt(self.rows_written)) / @as(f64, @floatFromInt(total));
    }
};

pub const WriteStats = struct {
    files_written: u32 = 0,
    bytes_written: u64 = 0,
};

pub const RowMutation = struct {
    table_name: []const u8,
    primary_key: []const u8,
};

pub const CopyFormat = enum {
    csv,
    parquet,
    npy,
};

pub const ReaderOptions = struct {
    delimiter: u8 = ',',
    has_header: bool = true,
    quote: u8 = '"',
};

pub fn trimLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r\n");
}

test "stats success rate" {
    var stats = ImportStats{ .rows_written = 8, .rows_failed = 2 };
    try std.testing.expectApproxEqRel(@as(f64, 0.8), stats.successRate(), 0.0001);
}

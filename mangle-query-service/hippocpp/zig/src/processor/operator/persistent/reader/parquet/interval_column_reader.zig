//! Interval Parquet column reader.

const base = @import("column_reader.zig");

pub const IntervalColumnReader = struct {
    inner: base.ColumnReader,

    pub fn init(value_count: u64) IntervalColumnReader {
        return .{ .inner = base.ColumnReader.init("interval", value_count) };
    }
};
